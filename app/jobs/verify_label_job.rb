# frozen_string_literal: true

# Orchestrates one verification: extraction (or cached reuse by blob
# checksum), the legibility gate, rules evaluation, persistence, and the
# structured log entry. One isolated job per label - a failing row never
# takes its batch siblings down.
class VerifyLabelJob < ApplicationJob
  queue_as :verification

  QUALITY_MODEL_ID = "quality-v1"
  VLM_MODE = "vlm"
  QUALITY_MODE = "quality"
  OCR_FIRST_MODE = "ocr_first"
  VERIFIER_V2_MODE = "verifier_v2"
  OCR_ONLY_MODE = "ocr_only"
  OCR_THEN_VLM_MODE = "ocr_then_vlm"
  VERIFIER_V2_MODES = [ VERIFIER_V2_MODE, OCR_ONLY_MODE, OCR_THEN_VLM_MODE ].freeze
  VALID_EXTRACTION_MODES = [ VLM_MODE, QUALITY_MODE, OCR_FIRST_MODE, *VERIFIER_V2_MODES ].freeze
  VERIFY_CONCURRENCY = Integer(ENV.fetch("VERIFY_CONCURRENCY", ENV.fetch("OCR_CONCURRENCY", "1")))
  DEFAULT_PRIORITY = Integer(ENV.fetch("VERIFY_JOB_PRIORITY", "10"))

  if respond_to?(:limits_concurrency)
    limits_concurrency to: VERIFY_CONCURRENCY, key: "vision_api"
  end

  retry_on Extraction::ExtractionError, wait: :polynomially_longer, attempts: 3 do |job, error|
    application = LabelApplication.find_by(id: job.arguments.first)
    if application
      attempt = job.instance_variable_get(:@verification_attempt) || job.send(
        :attempt_for,
        application: application,
        verification_attempt_id: job.arguments[4]
      )
      job.send(:record_error_for_attempt, application: application, error: error, attempt: attempt, stage_timings: {})
    end
  end

  # Test seam and deployment seam in one: the factory builds the real
  # connector by default. The two arguments are the per-run override
  # (the validation model menu); nil provider means the configured
  # default.
  class_attribute :extractor_factory, default: ->(provider, model) {
    if provider
      Extraction::ExtractorFactory.build_for(provider: provider, model: model)
    else
      Extraction::ExtractorFactory.build
    end
  }
  class_attribute :ocr_engine_factory, default: -> { Extraction::OcrFactory.build }
  class_attribute :ocr_engine_key_factory, default: -> { Extraction::OcrFactory.cache_key }
  class_attribute :ocr_region_engine_factory, default: -> { Extraction::OcrFactory.build_fast }
  class_attribute :ocr_region_refiner_factory, default: -> {
    Rails.application.config.x.extraction.ocr_region_refinement ? Extraction::RegionRefiner : Extraction::NoopRegionRefiner
  }
  class_attribute :extraction_reuse_enabled, default: true

  def self.default_model_id
    case Rails.application.config.x.extraction.mode
    when VERIFIER_V2_MODE then VerifierV2::MODEL_ID
    when OCR_ONLY_MODE then VerifierV2::MODEL_ID
    when OCR_THEN_VLM_MODE then VerifierV2::MODEL_ID
    when QUALITY_MODE then QUALITY_MODEL_ID
    when OCR_FIRST_MODE then Extraction::OcrFirstPayload::MODEL_ID
    else
      extractor_factory.call(nil, nil).model_id
    end
  end

  def self.configured_concurrency
    VERIFY_CONCURRENCY
  end

  def perform(label_application_id, provider = nil, model = nil, mode = nil, verification_attempt_id = nil)
    stage_metrics = {}
    extraction_mode = effective_extraction_mode(provider, mode)
    context = { label_application_id: label_application_id, provider: provider, model: model, mode: extraction_mode }

    application = measure_stage(stage_metrics, "load_application", context) do
      LabelApplication.find(label_application_id)
    end
    @verification_attempt = attempt_for(application: application, verification_attempt_id: verification_attempt_id)
    if use_verifier_v2?(extraction_mode)
      return VerifierV2.verify(
        label_application: application,
        attempt: @verification_attempt,
        mode: verifier_v2_mode(extraction_mode),
        provider: provider,
        model: model
      )
    end

    @verification_attempt.start_processing! if @verification_attempt.queued?
    raise ActiveRecord::RecordNotFound, "no artwork attached" unless application.artwork.attached?

    started = monotonic_ms
    extractor = build_extractor_for_mode(extraction_mode, provider, model, stage_metrics, context)
    model_id = reusable_model_id(extraction_mode, extractor)
    run_context = context.merge(model_id: model_id)

    artworks = measure_stage(stage_metrics, "artwork_download", run_context) do
      artwork_sources(application)
    end

    reused = measure_stage(stage_metrics, "extraction_reuse_lookup", run_context) do
      reusable_extraction(application, model_id)
    end

    if reused
      raw = reused.extraction
      verification = evaluate_and_persist(
        application: application,
        raw: raw,
        model_id: reused.model_id,
        reused: true,
        duplicate_of: reused.label_application_id == application.id ? nil : reused.label_application,
        started: started,
        stage_metrics: stage_metrics
      )
    else
      extraction = extract_raw(
        application: application,
        artworks: artworks,
        extractor: extractor,
        extraction_mode: extraction_mode,
        provider: provider,
        model: model,
        stage_metrics: stage_metrics,
        context: run_context
      )

      verification = evaluate_and_persist(
        application: application,
        raw: extraction.raw,
        model_id: extraction.model_id,
        reused: false,
        duplicate_of: nil,
        started: started,
        stage_metrics: stage_metrics
      )
    end

    log_verification(verification, stage_metrics)
    @verification_attempt.finish_with!(verification: verification, stage_timings: stage_metrics)
    verification
  rescue Extraction::ExtractionError
    raise
  rescue StandardError => error
    record_unexpected_error(
      label_application_id: label_application_id,
      verification_attempt_id: verification_attempt_id,
      error: error,
      stage_timings: defined?(stage_metrics) ? stage_metrics : {}
    )
    raise
  end

  private

  RawExtraction = Data.define(:raw, :model_id)

  def effective_extraction_mode(provider, mode)
    selected = mode.presence || Rails.application.config.x.extraction.mode
    selected = VLM_MODE if provider.present? && mode.blank?
    unless VALID_EXTRACTION_MODES.include?(selected)
      raise Extraction::ExtractionError, "unknown EXTRACTION_MODE #{selected.inspect} " \
                                         "(#{VALID_EXTRACTION_MODES.join(' | ')})"
    end
    selected
  end

  def use_verifier_v2?(extraction_mode)
    VERIFIER_V2_MODES.include?(extraction_mode) || ENV.fetch("USE_VERIFIER_V2", "false") == "true"
  end

  def verifier_v2_mode(extraction_mode)
    return extraction_mode if VERIFIER_V2_MODES.include?(extraction_mode)

    VERIFIER_V2_MODE
  end

  def build_extractor_for_mode(extraction_mode, provider, model, stage_metrics, context)
    return nil unless extraction_mode == VLM_MODE

    measure_stage(stage_metrics, "build_extractor", context) do
      extractor_factory.call(provider, model)
    end
  end

  def reusable_model_id(extraction_mode, extractor)
    case extraction_mode
    when VERIFIER_V2_MODE then VerifierV2::MODEL_ID
    when QUALITY_MODE then QUALITY_MODEL_ID
    when OCR_FIRST_MODE then Extraction::OcrFirstPayload::MODEL_ID
    else extractor.model_id
    end
  end

  def extract_raw(application:, artworks:, extractor:, extraction_mode:, provider:, model:, stage_metrics:, context:)
    case extraction_mode
    when QUALITY_MODE
      extract_quality(application: application, artworks: artworks, provider: provider, model: model,
                      stage_metrics: stage_metrics, context: context)
    when OCR_FIRST_MODE
      RawExtraction.new(
        raw: extract_ocr_first(application: application, artworks: artworks, stage_metrics: stage_metrics,
                               context: context),
        model_id: Extraction::OcrFirstPayload::MODEL_ID
      )
    else
      RawExtraction.new(
        raw: extract_vlm(application: application, artworks: artworks, extractor: extractor,
                         stage_metrics: stage_metrics, context: context, refine_with_ocr: false),
        model_id: extractor.model_id
      )
    end
  end

  def extract_quality(application:, artworks:, provider:, model:, stage_metrics:, context:)
    ocr_raw = extract_ocr_first(application: application, artworks: artworks, stage_metrics: stage_metrics,
                                context: context.merge(model_id: QUALITY_MODEL_ID))
    ocr_evaluation = evaluate_raw(
      application: application, raw: ocr_raw, model_id: QUALITY_MODEL_ID,
      stage_metrics: stage_metrics
    )
    return RawExtraction.new(raw: ocr_raw, model_id: QUALITY_MODEL_ID) if quality_ocr_acceptable?(ocr_evaluation)

    extractor = measure_stage(stage_metrics, "build_extractor", context) do
      extractor_factory.call(provider, model)
    end
    RawExtraction.new(
      raw: extract_vlm(application: application, artworks: artworks, extractor: extractor,
                       stage_metrics: stage_metrics, context: context.merge(model_id: extractor.model_id),
                       refine_with_ocr: true),
      model_id: QUALITY_MODEL_ID
    )
  rescue Extraction::OcrError => e
    Rails.logger.warn(JSON.generate({
      event: "quality_ocr_first_failed", error: e.message.to_s.first(300)
    }))
    extractor = measure_stage(stage_metrics, "build_extractor", context) do
      extractor_factory.call(provider, model)
    end
    RawExtraction.new(
      raw: extract_vlm(application: application, artworks: artworks, extractor: extractor,
                       stage_metrics: stage_metrics, context: context.merge(model_id: extractor.model_id),
                       refine_with_ocr: true),
      model_id: QUALITY_MODEL_ID
    )
  end

  def quality_ocr_acceptable?(evaluation)
    evaluation.overall_verdict != "request_retake" &&
      evaluation.checks.none? { |check| check.verdict == "fail" }
  end

  def extract_ocr_first(application:, artworks:, stage_metrics:, context:)
    pages = measure_stage(stage_metrics, "ocr_pages", context) do
      Extraction::OcrPagePool.read(
        artworks: artworks,
        engine: ocr_engine_factory.call,
        engine_key: ocr_engine_key_factory.call
      )
    end
    measure_stage(stage_metrics, "ocr_first_payload", context) do
      Extraction::OcrFirstPayload.build(
        application: application,
        pages: pages,
        threshold: Rails.application.config.x.extraction.ocr_match_threshold
      )
    end
  end

  def extract_vlm(application:, artworks:, extractor:, stage_metrics:, context:, refine_with_ocr:)
    raw = measure_stage(stage_metrics, "vlm_extraction", context) do
      extractor.extract(artworks: artworks, application: application).raw
    end
    raw = measure_stage(stage_metrics, "vlm_reconciliation", context) do
      Extraction::VlmReconciler.reconcile(payload: raw, application: application)
    end
    return raw unless refine_with_ocr

    measure_stage(stage_metrics, "ocr_refinement", context.merge(engine_key: ocr_engine_key_factory.call)) do
      Extraction::Refinement.new(
        engine: ocr_engine_factory.call,
        region_engine: ocr_region_engine_factory.call,
        region_refiner: ocr_region_refiner_factory.call,
        engine_key: ocr_engine_key_factory.call,
        threshold: Rails.application.config.x.extraction.ocr_match_threshold
      ).refine(raw: raw, artworks: artworks, application: application)
    end
  end

  # Front + optional back.
  def artwork_sources(application)
    [ application.artwork, application.back_artwork ].select(&:attached?).map do |attachment|
      Extraction::ArtworkSource.new(
        data: attachment.download,
        content_type: attachment.content_type,
        checksum: attachment.blob.checksum
      )
    end
  end

  def evaluate_and_persist(application:, raw:, model_id:, reused:, duplicate_of:, started:, stage_metrics:)
    evaluation = evaluate_raw(
      application: application, raw: raw, model_id: model_id,
      stage_metrics: stage_metrics
    )
    persist_evaluation(
      application: application, evaluation: evaluation, reused: reused,
      duplicate_of: duplicate_of, started: started, stage_metrics: stage_metrics
    )
  end

  Evaluation = Data.define(:raw, :model_id, :facts, :checks, :overall_verdict)

  def evaluate_raw(application:, raw:, model_id:, stage_metrics:)
    facts = measure_stage(stage_metrics, "facts_mapping", { label_application_id: application.id, model_id: model_id }) do
      Extraction::FactsMapper.to_facts(raw)
    end

    if retake_needed?(facts)
      return Evaluation.new(raw: raw, model_id: model_id, facts: facts, checks: [], overall_verdict: "request_retake")
    end

    checks = measure_stage(stage_metrics, "rules_evaluation", { label_application_id: application.id, model_id: model_id }) do
      Rules::Engine.evaluate(application: application, facts: facts)
    end
    checks << coverage_note if sparse_extraction?(checks)
    Evaluation.new(raw: raw, model_id: model_id, facts: facts, checks: checks, overall_verdict: FieldCheck.overall(checks))
  end

  def persist_evaluation(application:, evaluation:, reused:, duplicate_of:, started:, stage_metrics:)
    checks = evaluation.checks.dup
    checks << duplicate_note(duplicate_of) if duplicate_of
    overall_verdict = checks.empty? ? evaluation.overall_verdict : FieldCheck.overall(checks)
    measure_stage(stage_metrics, "verification_persist", { label_application_id: application.id, model_id: evaluation.model_id }) do
      application.verifications.create!(
        overall_verdict: overall_verdict,
        field_checks: checks,
        extraction: evaluation.raw,
        extraction_reused: reused,
        model_id: evaluation.model_id,
        artwork_fingerprint: artwork_fingerprint(application),
        latency_ms: monotonic_ms - started
      )
    end
  end

  def retake_needed?(facts)
    return true if facts.legible == false

    threshold = Rails.application.config.x.extraction.min_confidence
    facts.confidence.is_a?(Numeric) && facts.confidence < threshold
  end

  def reusable_extraction(application, model_id)
    return nil unless extraction_reuse_enabled

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

  SPARSE_EXTRACTION_FAILS = 3
  SPARSE_EXTRACTION_VERDICTS = %w[fail needs_review].freeze

  def sparse_extraction?(checks)
    checks.count { |c| SPARSE_EXTRACTION_VERDICTS.include?(c.verdict) && c.extracted.to_s.strip.empty? } >= SPARSE_EXTRACTION_FAILS
  end

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

  def attempt_for(application:, verification_attempt_id:)
    if verification_attempt_id.present?
      application.verification_attempts.find(verification_attempt_id)
    else
      application.verification_attempts.create!
    end
  end

  def record_error(application, error)
    attempt = current_error_attempt_for(application)
    record_error_for_attempt(application: application, error: error, attempt: attempt, stage_timings: {})
  end

  def current_error_attempt_for(application)
    attempt = application.verification_attempts.where(state: %w[processing queued]).order(created_at: :desc).first
    attempt ||= application.verification_attempts.create!
    attempt.start_processing! if attempt.queued?
    attempt
  end

  def record_unexpected_error(label_application_id:, verification_attempt_id:, error:, stage_timings:)
    application = LabelApplication.find_by(id: label_application_id)
    return if application.nil?

    attempt = @verification_attempt || attempt_for(
      application: application,
      verification_attempt_id: verification_attempt_id
    )
    return if attempt.processing_completed_at.present?

    record_error_for_attempt(
      application: application,
      error: error,
      attempt: attempt,
      stage_timings: stage_timings
    )
  rescue StandardError => recording_error
    Rails.logger.error(JSON.generate({
      event: "verification_error_recording_failed",
      label_application_id: label_application_id,
      verification_attempt_id: verification_attempt_id,
      original_error_class: error.class.name,
      original_error_message: error.message.to_s.first(500),
      recording_error_class: recording_error.class.name,
      recording_error_message: recording_error.message.to_s.first(500)
    }))
  end

  def record_error_for_attempt(application:, error:, attempt:, stage_timings:)
    verification = application.verifications.create!(
      overall_verdict: "error",
      field_checks: [],
      error_message: error.message.to_s.first(500)
    )
    attempt.update!(verification: verification)
    attempt.fail_with!(error: error, context: {}, stage_timings: stage_timings)
    log_verification(verification, stage_timings)
  end

  def log_verification(verification, stage_metrics)
    Rails.logger.info(JSON.generate({
      event: "verification_completed",
      label_application_id: verification.label_application_id,
      batch_id: verification.label_application.batch_id,
      verification_id: verification.id,
      overall_verdict: verification.overall_verdict,
      extraction_reused: verification.extraction_reused,
      model: verification.model_id,
      latency_ms: verification.latency_ms,
      stage_ms: stage_metrics
    }))
  end

  def measure_stage(stage_metrics, stage, payload)
    started = monotonic_ms
    ActiveSupport::Notifications.instrument(
      "verification.stage.label_verifier",
      payload.merge(stage: stage)
    ) do
      yield
    end
  ensure
    stage_metrics[stage] = monotonic_ms - started if stage_metrics
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
