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
  class_attribute :extractor_factory, default: -> { LabelExtractor.build }
  class_attribute :ocr_factory, default: -> { Extraction::OcrClient.build }

  def perform(label_application_id)
    application = LabelApplication.find(label_application_id)
    raise ActiveRecord::RecordNotFound, "no artwork attached" unless application.artwork.attached?

    started = monotonic_ms
    reused = reusable_extraction(application)

    if reused
      verification = evaluate_and_persist(
        application: application,
        raw: refine_extraction(
          raw: reused.extraction,
          data: application.artwork.download,
          content_type: application.artwork.content_type,
          application: application
        ),
        model_id: reused.model_id,
        reused: true,
        duplicate_of: reused.label_application_id == application.id ? nil : reused.label_application,
        started: started
      )
    else
      data = application.artwork.download
      content_type = application.artwork.content_type
      result = extractor_factory.call.extract(data: data, content_type: content_type)
      verification = evaluate_and_persist(
        application: application,
        raw: refine_extraction(raw: result.raw, data: data, content_type: content_type, application: application),
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

  # OCR-dependent refinement: re-anchors boxes to word geometry, then
  # reconciles the fanciful name against the application's declared value.
  # Strictly best-effort: any OCR failure (missing binary, unreadable
  # artwork) logs a warning and returns the payload unchanged - it never
  # fails a verification. Runs on reused extractions too: OCR is local
  # and cheap, and reconciliation depends on the application, which can
  # differ across duplicate artwork.
  def refine_extraction(raw:, data:, content_type:, application:)
    threshold = Rails.application.config.x.extraction.ocr_match_threshold
    pages = ocr_factory.call.read(data: data, content_type: content_type)
    grounded = Extraction::BboxGrounder.ground(payload: raw, pages: pages, threshold: threshold)
    Extraction::FieldReconciler.reconcile_fanciful_name(
      payload: grounded,
      pages: pages,
      expected: application.fanciful_name,
      threshold: threshold
    )
  rescue Extraction::OcrError => e
    Rails.logger.warn(JSON.generate({
      event: "extraction_refinement_failed", error: e.message.to_s.first(300)
    }))
    raw
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
        latency_ms: monotonic_ms - started
      )
    end

    checks = Rules::Engine.evaluate(application: application, facts: facts)
    checks << duplicate_note(duplicate_of) if duplicate_of

    application.verifications.create!(
      overall_verdict: FieldCheck.overall(checks),
      field_checks: checks,
      extraction: raw,
      extraction_reused: reused,
      model_id: model_id,
      latency_ms: monotonic_ms - started
    )
  end

  def retake_needed?(facts)
    return true if facts.legible == false

    threshold = Rails.application.config.x.extraction.min_confidence
    facts.confidence.is_a?(Numeric) && facts.confidence < threshold
  end

  # The same artwork bytes (matched by blob checksum) always extract the
  # same facts - skip the vision call and re-run only the rules stage.
  def reusable_extraction(application)
    checksum = application.artwork.blob.checksum

    Verification.completed.with_extraction
                .joins(label_application: { artwork_attachment: :blob })
                .where(active_storage_blobs: { checksum: checksum })
                .order(created_at: :desc)
                .first
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
