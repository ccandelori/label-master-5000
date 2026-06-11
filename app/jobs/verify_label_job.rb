# frozen_string_literal: true

# Orchestrates one verification: extraction (or cached reuse by blob
# checksum), the legibility gate, rules evaluation, persistence, and the
# structured log entry. One isolated job per label - a failing row never
# takes its batch siblings down.
class VerifyLabelJob < ApplicationJob
  queue_as :default

  # Vision API concurrency cap (effective under Solid Queue).
  if respond_to?(:limits_concurrency)
    limits_concurrency to: Integer(ENV.fetch("VERIFY_CONCURRENCY", "4")), key: "vision_api"
  end

  retry_on Extraction::ExtractionError, wait: :polynomially_longer, attempts: 3 do |job, error|
    application = LabelApplication.find_by(id: job.arguments.first)
    job.send(:record_error, application, error) if application
  end

  # Test seam and deployment seam in one: the factory builds the real
  # connector by default.
  class_attribute :extractor_factory, default: -> { Extraction::ExtractorFactory.build }
  class_attribute :ocr_factory, default: -> { Extraction::OcrFactory.build }

  def perform(label_application_id)
    application = LabelApplication.find(label_application_id)
    raise ActiveRecord::RecordNotFound, "no artwork attached" unless application.artwork.attached?

    started = monotonic_ms
    extractor = extractor_factory.call
    artworks = artwork_sources(application)
    reused = reusable_extraction(application, extractor.model_id)

    if reused
      verification = evaluate_and_persist(
        application: application,
        raw: refine_extraction(raw: reused.extraction, artworks: artworks, application: application),
        model_id: reused.model_id,
        reused: true,
        duplicate_of: reused.label_application_id == application.id ? nil : reused.label_application,
        started: started
      )
    else
      result = extractor.extract(artworks: artworks)
      verification = evaluate_and_persist(
        application: application,
        raw: refine_extraction(raw: result.raw, artworks: artworks, application: application),
        model_id: result.model_id,
        reused: false,
        duplicate_of: nil,
        started: started
      )
    end

    log_verification(verification)
    verification
  end

  private

  # Front label first, optional back second; position is the page the
  # rest of the pipeline sees.
  def artwork_sources(application)
    [ application.artwork, application.back_artwork ].select(&:attached?).map do |attachment|
      Extraction::ArtworkSource.new(
        data: attachment.download,
        content_type: attachment.content_type,
        checksum: attachment.blob.checksum
      )
    end
  end

  def refine_extraction(raw:, artworks:, application:)
    Extraction::Refinement.new(
      engine: ocr_factory.call,
      engine_key: Extraction::OcrFactory.cache_key,
      threshold: Rails.application.config.x.extraction.ocr_match_threshold
    ).refine(raw: raw, artworks: artworks, application: application)
  end

  def evaluate_and_persist(application:, raw:, model_id:, reused:, duplicate_of:, started:)
    facts = Extraction::FactsMapper.to_facts(raw)

    if retake_needed?(facts)
      return application.verifications.create!(
        overall_verdict: "request_retake",
        field_checks: [],
        extraction: raw,
        extraction_reused: reused,
        model_id: model_id,
        artwork_fingerprint: artwork_fingerprint(application),
        latency_ms: monotonic_ms - started
      )
    end

    checks = Rules::Engine.evaluate(application: application, facts: facts)
    checks << duplicate_note(duplicate_of) if duplicate_of
    checks << coverage_note if sparse_extraction?(checks)

    application.verifications.create!(
      overall_verdict: FieldCheck.overall(checks),
      field_checks: checks,
      extraction: raw,
      extraction_reused: reused,
      model_id: model_id,
      artwork_fingerprint: artwork_fingerprint(application),
      latency_ms: monotonic_ms - started
    )
  end

  def retake_needed?(facts)
    return true if facts.legible == false

    threshold = Rails.application.config.x.extraction.min_confidence
    facts.confidence.is_a?(Numeric) && facts.confidence < threshold
  end

  # The same artwork bytes always extract the same facts - for the same
  # model. Reuse keys on the artwork fingerprint (front checksum, plus
  # the back label's when attached - the same front with a different back
  # is a different reading) and the configured extractor's model, so one
  # provider's reading is never passed off as another's.
  def reusable_extraction(application, model_id)
    Verification.completed.with_extraction
                .where(model_id: model_id, artwork_fingerprint: artwork_fingerprint(application))
                .order(created_at: :desc)
                .first
  end

  def artwork_fingerprint(application)
    [ application.artwork, application.back_artwork ]
      .select(&:attached?).map { |attachment| attachment.blob.checksum }.join("+")
  end

  def duplicate_note(other_application)
    FieldCheck.new(
      field: "duplicate_artwork",
      verdict: "pass_with_note",
      expected: nil,
      extracted: nil,
      citation: "Internal: blob checksum match",
      note: "This artwork was previously verified as application #{other_application.serial_number} (##{other_application.id})"
    )
  end

  # Several mandatory items failing with NOTHING extracted usually means
  # unreadable artwork rather than a label missing all of them at once.
  SPARSE_EXTRACTION_FAILS = 3

  def sparse_extraction?(checks)
    checks.count { |c| c.verdict == "fail" && c.extracted.to_s.strip.empty? } >= SPARSE_EXTRACTION_FAILS
  end

  # Advisory only - it rides along with the failures that triggered it
  # and never outranks them in FieldCheck.overall.
  def coverage_note
    FieldCheck.new(
      field: "artwork_quality",
      verdict: "pass_with_note",
      expected: nil,
      extracted: nil,
      citation: "Internal: extraction coverage",
      note: "Several mandatory items could not be read from the artwork at all - consider requesting a better image before rejecting"
    )
  end

  def record_error(application, error)
    verification = application.verifications.create!(
      overall_verdict: "error",
      field_checks: [],
      error_message: error.message.to_s.first(500)
    )
    log_verification(verification)
  end

  def log_verification(verification)
    Rails.logger.info(JSON.generate({
      event: "verification_completed",
      label_application_id: verification.label_application_id,
      batch_id: verification.label_application.batch_id,
      verification_id: verification.id,
      overall_verdict: verification.overall_verdict,
      extraction_reused: verification.extraction_reused,
      model: verification.model_id,
      latency_ms: verification.latency_ms
    }))
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
