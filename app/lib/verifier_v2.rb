# frozen_string_literal: true

# Evidence-first verifier orchestration. The job owns queue admission and
# retries; this object owns one attempt's processing lifecycle, timing,
# OCR evidence acquisition, bounded escalation, focused VLM adjudication,
# rule evaluation, persistence, and operational error recording.
module VerifierV2
  MODEL_ID = "verifier-v2-v1"
  BLOCKING_MODE = "verifier_v2"
  OCR_ONLY_MODE = "ocr_only"
  OCR_THEN_VLM_MODE = "ocr_then_vlm"
  MODES = [ BLOCKING_MODE, OCR_ONLY_MODE, OCR_THEN_VLM_MODE ].freeze
  VLM_FIELD_LIMIT = 6
  DEFAULT_LATENCY_BUDGET_MS = 10_000.0
  ESCALATION_MIN_REMAINING_MS = 3_000.0
  ESCALATION_CONFIDENCE_THRESHOLD = 0.6
  UNRESOLVED_VERDICTS = %w[fail needs_review].freeze
  ADJUDICATION_FIELD_PRIORITY = %w[
    brand_name fanciful_name class_type_designation net_contents
    alcohol_content government_warning_text government_warning_prefix
    name_and_address appellation vintage
  ].freeze
  SENSITIVE_PATTERNS = [
    /sk-[A-Za-z0-9_\-]{8,}/,
    /(api[_-]?key["'=:\s]+)[^"'\s,}]+/i,
    /(authorization["'=:\s]+bearer\s+)[^"'\s,}]+/i
  ].freeze

  module_function

  def build(provider:, model:)
    Runner.new(
      ocr_engine: Extraction::OcrFactory.build,
      ocr_engine_key: Extraction::OcrFactory.cache_key,
      escalation_engine: Extraction::OcrFactory.build_fast,
      vlm_adjudicator: Extraction::VlmAdjudicator.build_for(provider: provider, model: model),
      vlm_provider: provider,
      vlm_model: model,
      progress_reporter: ProgressReporter,
      ocr_readiness: -> { Extraction::RuntimeDependencies.check_ocr_ready },
      config: Rails.application.config.x.extraction
    )
  end

  def verify(label_application:, attempt:, mode:, provider:, model:)
    build(provider: provider, model: model).verify(label_application: label_application, attempt: attempt, mode: mode)
  end

  def refine_verification(verification:, provider:, model:)
    build(provider: provider, model: model).refine_verification(verification: verification)
  end

  class Runner
    def initialize(ocr_engine:, ocr_engine_key:, escalation_engine:, vlm_adjudicator:, vlm_provider:, vlm_model:, progress_reporter:, ocr_readiness:, config:)
      @ocr_engine = ocr_engine
      @ocr_engine_key = ocr_engine_key
      @escalation_engine = escalation_engine
      @vlm_adjudicator = vlm_adjudicator
      @vlm_provider = vlm_provider
      @vlm_model = vlm_model
      @progress_reporter = progress_reporter
      @ocr_readiness = ocr_readiness
      @config = config
    end

    def verify(label_application:, attempt:, mode:)
      raise ArgumentError, "unknown verifier mode #{mode.inspect}" unless MODES.include?(mode)

      stage_timings = {}
      started = monotonic_ms
      attempt.start_processing! if attempt.queued?

      verification = run_pipeline(
        application: label_application,
        attempt: attempt,
        stage_timings: stage_timings,
        started: started,
        mode: mode
      )
      final_timings = stage_timings.merge("total_ms" => monotonic_ms - started)
      attempt.finish_with!(verification: verification, stage_timings: final_timings)
      log_completion(application: label_application, attempt: attempt, verification: verification, stage_timings: final_timings)
      verification
    rescue StandardError => e
      record_error(application: label_application, attempt: attempt, error: e, stage_timings: stage_timings)
    end

    def refine_verification(verification:)
      started = monotonic_ms
      application = verification.label_application
      artworks = artwork_sources(application)
      checks = verification.field_checks
      fields = unresolved_fields(application: application, checks: checks).first(VLM_FIELD_LIMIT)
      images = adjudication_images(artworks)
      if fields.empty? || images.empty?
        verification.update!(
          extraction: refined_raw(
            raw: verification.extraction || {},
            fields: fields.map(&:name),
            adjudications: [],
            status: "skipped",
            started: started
          )
        )
        return verification
      end

      adjudications = adjudicate_across_artworks(fields: fields, images: images)
      evaluation = Evaluation.new(
        facts: nil,
        checks: checks,
        overall_verdict: checks.empty? ? verification.overall_verdict : FieldCheck.overall(checks)
      )
      refined = apply_adjudications(evaluation: evaluation, adjudications: adjudications)
      verification.update!(
        overall_verdict: refined.overall_verdict,
        field_checks: refined.checks,
        extraction: refined_raw(
          raw: verification.extraction || {},
          fields: fields.map(&:name),
          adjudications: adjudications,
          status: "complete",
          started: started
        )
      )
      verification
    end

    private

    def run_pipeline(application:, attempt:, stage_timings:, started:, mode:)
      ensure_artwork!(application)
      measure(stage_timings, "ocr_readiness_ms", application: application, attempt: attempt) do
        ensure_ocr_ready!
      end
      artworks = measure(stage_timings, "image_prep_ms", application: application, attempt: attempt) do
        artwork_sources(application)
      end
      evidence = measure(stage_timings, "ocr_ms", application: application, attempt: attempt) do
        Extraction::OcrEvidenceStore.read(artworks: artworks, engine: @ocr_engine, engine_key: @ocr_engine_key)
      end
      evidence = escalated_evidence(
        application: application,
        artworks: artworks,
        evidence: evidence,
        stage_timings: stage_timings,
        started: started,
        attempt: attempt
      )
      raw = measure(stage_timings, "candidate_match_ms", application: application, attempt: attempt) do
        build_payload(application: application, evidence: evidence)
      end
      evaluation = evaluate(application: application, raw: raw, stage_timings: stage_timings, attempt: attempt)
      return persist_ocr_evaluation(
        application: application,
        raw: raw,
        evaluation: evaluation,
        started: started,
        stage_timings: stage_timings,
        attempt: attempt,
        mode: mode
      ) if mode != BLOCKING_MODE

      adjudications = adjudicate_unresolved(application: application, artworks: artworks, checks: evaluation.checks,
                                            stage_timings: stage_timings, attempt: attempt)
      evaluation = apply_adjudications(evaluation: evaluation, adjudications: adjudications)
      raw = raw.merge("vlm_adjudications" => adjudications.map { |result| adjudication_to_h(result) })
      persist(
        application: application,
        raw: raw,
        evaluation: evaluation,
        started: started,
        stage_timings: stage_timings,
        attempt: attempt
      )
    end

    def persist_ocr_evaluation(application:, raw:, evaluation:, started:, stage_timings:, attempt:, mode:)
      fields = unresolved_fields(application: application, checks: evaluation.checks).first(VLM_FIELD_LIMIT)
      refined_raw = mode == OCR_THEN_VLM_MODE ? ocr_then_vlm_raw(raw: raw, fields: fields) : raw
      verification = persist(
        application: application,
        raw: refined_raw,
        evaluation: evaluation,
        started: started,
        stage_timings: stage_timings,
        attempt: attempt
      )
      RefineVerificationJob.perform_later(verification.id, @vlm_provider, @vlm_model) if mode == OCR_THEN_VLM_MODE && fields.any?
      verification
    end

    Evaluation = Data.define(:facts, :checks, :overall_verdict)

    def ensure_ocr_ready!
      readiness = @ocr_readiness.call
      return if readiness.ok?

      raise Extraction::OcrError, readiness.error_message
    end

    def escalated_evidence(application:, artworks:, evidence:, stage_timings:, started:, attempt:)
      missing_fields = measure(stage_timings, "candidate_probe_ms", application: application, attempt: attempt) do
        missing_expected_fields(application: application, evidence: evidence)
      end
      return evidence if missing_fields.empty?

      result = measure(stage_timings, "ocr_escalation_ms", application: application, attempt: attempt) do
        Extraction::OcrEscalation.run(
          artworks: artworks,
          evidence: evidence,
          engine: @escalation_engine,
          engine_key: @ocr_engine_key,
          missing_fields: missing_fields,
          deadline_ms: started + DEFAULT_LATENCY_BUDGET_MS,
          min_remaining_ms: ESCALATION_MIN_REMAINING_MS,
          confidence_threshold: ESCALATION_CONFIDENCE_THRESHOLD,
          match_threshold: @config.ocr_match_threshold
        )
      end
      result.evidence
    end

    def build_payload(application:, evidence:)
      pages = raw_pages_from_evidence(evidence)
      payload = Extraction::OcrFirstPayload.build(
        application: application,
        pages: pages,
        threshold: @config.ocr_match_threshold
      )
      payload.merge(
        "pipeline" => MODEL_ID,
        "ocr_engine_key" => evidence.engine_key,
        "ocr_word_count" => evidence.words.size
      )
    end

    def evaluate(application:, raw:, stage_timings:, attempt:)
      facts = measure(stage_timings, "facts_mapping_ms", application: application, attempt: attempt) do
        Extraction::FactsMapper.to_facts(raw)
      end
      return Evaluation.new(facts: facts, checks: [], overall_verdict: "request_retake") if retake_needed?(facts)

      checks = measure(stage_timings, "rules_ms", application: application, attempt: attempt) do
        Rules::Engine.evaluate(application: application, facts: facts)
      end
      Evaluation.new(facts: facts, checks: checks, overall_verdict: FieldCheck.overall(checks))
    end

    def adjudicate_unresolved(application:, artworks:, checks:, stage_timings:, attempt:)
      images = adjudication_images(artworks)
      return [] if images.empty?

      fields = unresolved_fields(application: application, checks: checks)
      return [] if fields.empty?

      measure(stage_timings, "vlm_adjudication_ms", application: application, attempt: attempt) do
        adjudicate_across_artworks(fields: fields.first(VLM_FIELD_LIMIT), images: images)
      end
    end

    def adjudicate_across_artworks(fields:, images:)
      results = images.each_with_index.flat_map do |image, index|
        @vlm_adjudicator.adjudicate(fields: fields, image: image.data, content_type: image.content_type).map do |result|
          result_for_artwork(result: result, page: index + 1)
        end
      end
      merge_adjudication_results(results)
    end

    def result_for_artwork(result:, page:)
      Extraction::VlmAdjudicator::Result.new(
        field: result.field,
        status: result.status,
        page: page,
        reason: result.reason,
        model_id: result.model_id
      )
    end

    def merge_adjudication_results(results)
      results.group_by(&:field).values.map do |field_results|
        field_results.find { |result| result.status == "present" } ||
          field_results.find { |result| result.status == "ambiguous" } ||
          field_results.first
      end
    end

    def apply_adjudications(evaluation:, adjudications:)
      present = adjudications.select { |result| result.status == "present" }.index_by(&:field)
      return evaluation if present.empty?

      checks = evaluation.checks.map do |check|
        result = present[check.field]
        if result && UNRESOLVED_VERDICTS.include?(check.verdict)
          adjudicated_check(check: check, result: result)
        else
          check
        end
      end
      Evaluation.new(facts: evaluation.facts, checks: checks, overall_verdict: FieldCheck.overall(checks))
    end

    def adjudicated_check(check:, result:)
      FieldCheck.new(
        field: check.field,
        verdict: "pass_with_note",
        expected: check.expected,
        extracted: "VLM present",
        citation: check.citation,
        note: "VLM confirmed the expected value is present; OCR could not verify exact text. #{result.reason}"
      )
    end

    def ocr_then_vlm_raw(raw:, fields:)
      raw.merge(
        "vlm_refinement" => {
          "status" => fields.any? ? "pending" : "skipped",
          "fields" => fields.map(&:name),
          "provider" => @vlm_provider,
          "model" => @vlm_model
        }
      )
    end

    def refined_raw(raw:, fields:, adjudications:, status:, started:)
      existing_adjudications = Array(raw["vlm_adjudications"])
      raw.merge(
        "vlm_adjudications" => existing_adjudications + adjudications.map { |result| adjudication_to_h(result) },
        "vlm_refinement" => {
          "status" => status,
          "fields" => fields,
          "provider" => @vlm_provider,
          "model" => @vlm_model,
          "duration_ms" => monotonic_ms - started
        }
      )
    end

    def persist(application:, raw:, evaluation:, started:, stage_timings:, attempt:)
      measure(stage_timings, "persistence_ms", application: application, attempt: attempt) do
        application.verifications.create!(
          overall_verdict: evaluation.overall_verdict,
          field_checks: evaluation.checks,
          extraction: raw,
          extraction_reused: false,
          model_id: MODEL_ID,
          artwork_fingerprint: artwork_fingerprint(application),
          latency_ms: monotonic_ms - started
        )
      end
    end

    def record_error(application:, attempt:, error:, stage_timings:)
      verification = application.verifications.create!(
        overall_verdict: "error",
        field_checks: [],
        error_message: error.message.to_s.first(500)
      )
      attempt.update!(verification: verification)
      attempt.fail_with!(
        error: error,
        context: error_context(error),
        stage_timings: stage_timings
      )
      log_error(application: application, attempt: attempt, verification: verification, error: error, stage_timings: stage_timings)
      verification
    end

    def missing_expected_fields(application:, evidence:)
      expected_fields(application).select do |field|
        Extraction::CandidateMatcher.find(
          query: field.expected_text,
          evidence: evidence,
          threshold: @config.ocr_match_threshold,
          limit: 1
        ).empty?
      end
    end

    def expected_fields(application)
      [
        expected_field(name: "brand_name", text: application.brand_name),
        expected_field(name: "fanciful_name", text: application.fanciful_name),
        expected_field(name: "class_type_designation", text: application.declared_class_type),
        expected_field(name: "net_contents", text: application.net_contents),
        expected_field(name: "name_address_statement", text: application.applicant_name_address),
        expected_field(name: "government_warning", text: Rules::Data.statutory_warning_text),
        expected_field(name: "alcohol_statement", text: alcohol_search_text(application))
      ].compact
    end

    def expected_field(name:, text:)
      return nil if text.to_s.strip.empty?
      return nil if Parsing::ApplicationValue.not_stated?(text)

      Extraction::OcrEscalation::ExpectedField.new(
        name: name,
        expected_text: text.to_s,
        bbox_hint: nil,
        page: 1
      )
    end

    def unresolved_fields(application:, checks:)
      fields = checks.filter_map do |check|
        next unless UNRESOLVED_VERDICTS.include?(check.verdict)

        text = expected_text_for_check(application: application, check: check)
        next if text.to_s.strip.empty?

        Extraction::VlmAdjudicator::Field.new(
          name: check.field,
          expected_text: text,
          bbox_hint: nil,
          page: 1
        )
      end
      prioritize_adjudication_fields(fields)
    end

    def prioritize_adjudication_fields(fields)
      fields.each_with_index
            .sort_by { |field, index| [ ADJUDICATION_FIELD_PRIORITY.index(field.name) || ADJUDICATION_FIELD_PRIORITY.size, index ] }
            .map(&:first)
    end

    def expected_text_for_check(application:, check:)
      case check.field
      when "brand_name" then application.brand_name
      when "fanciful_name" then application.fanciful_name
      when "class_type_designation" then application.declared_class_type
      when "net_contents" then net_contents_expected_text(application)
      when "name_and_address" then application.applicant_name_address
      when "government_warning_text", "government_warning_prefix" then Rules::Data.statutory_warning_text
      when "alcohol_content" then alcohol_expected_text(application)
      else check.expected
      end
    end

    def net_contents_expected_text(application)
      return application.net_contents unless Parsing::ApplicationValue.not_stated?(application.net_contents)

      "Any net contents statement, such as a volume in mL, L, fluid ounces, pints, quarts, or gallons"
    end

    def alcohol_expected_text(application)
      alcohol_search_text(application) || "Any alcohol content statement, such as ABV, ALC/VOL, alcohol by volume, or proof"
    end

    def adjudication_to_h(result)
      {
        "field" => result.field,
        "status" => result.status,
        "page" => result.page,
        "reason" => result.reason,
        "model_id" => result.model_id
      }
    end

    def raw_pages_from_evidence(evidence)
      evidence.pages.map do |page|
        Extraction::OcrClient::Page.new(
          number: page.number,
          width: page.width,
          height: page.height,
          words: page.words.map { |word| raw_word_from_evidence(word) }
        )
      end
    end

    def raw_word_from_evidence(word)
      Extraction::OcrClient.build_word(
        text: word.text,
        x: word.bbox.x,
        y: word.bbox.y,
        width: word.bbox.width,
        height: word.bbox.height,
        confidence: word.confidence
      )
    end

    def retake_needed?(facts)
      return true if facts.legible == false

      facts.confidence.is_a?(Numeric) && facts.confidence < @config.min_confidence
    end

    def ensure_artwork!(application)
      raise ActiveRecord::RecordNotFound, "no artwork attached" unless application.artwork.attached?
    end

    def artwork_sources(application)
      [ application.artwork, application.back_artwork ].select(&:attached?).map do |attachment|
        Extraction::ArtworkSource.new(
          data: attachment.download,
          content_type: attachment.content_type,
          checksum: attachment.blob.checksum
        )
      end
    end

    def adjudication_images(artworks)
      artworks.reject(&:pdf?)
    end

    def artwork_fingerprint(application)
      [ application.artwork, application.back_artwork ]
        .select(&:attached?).map { |attachment| attachment.blob.checksum }.join("+")
    end

    def alcohol_search_text(application)
      return nil unless application.alcohol_content.present?

      "#{application.alcohol_content}%"
    end

    def measure(stage_timings, stage, application:, attempt:)
      started = monotonic_ms
      @progress_reporter.stage_started(attempt: attempt, stage: stage)
      ActiveSupport::Notifications.instrument(
        "verification.stage.label_verifier",
        label_application_id: application.id,
        verification_attempt_id: attempt.id,
        stage: stage
      ) do
        yield
      end
    ensure
      duration = monotonic_ms - started
      stage_timings[stage] = duration
      @progress_reporter.stage_finished(attempt: attempt, stage: stage, duration_ms: duration) if @progress_reporter
    end

    def error_context(error)
      {
        "error_class" => error.class.name,
        "error_message" => redact(error.message.to_s).first(500),
        "ocr_engine" => @config.ocr_engine,
        "ocr_version" => @ocr_engine_key,
        "vlm_provider" => @vlm_provider || @config.provider,
        "vlm_model" => @vlm_model || @config.model,
        "stack_trace_sample" => Array(error.backtrace).first(10).map { |line| redact(line) }
      }
    end

    def log_completion(application:, attempt:, verification:, stage_timings:)
      Rails.logger.info(JSON.generate({
        event: "verifier_v2_completed",
        label_application_id: application.id,
        verification_attempt_id: attempt.id,
        verification_id: verification.id,
        state: attempt.state,
        overall_verdict: verification.overall_verdict,
        model_id: verification.model_id,
        stage_ms: stage_timings,
        queue_wait_ms: attempt.queue_wait_ms
      }))
    end

    def log_error(application:, attempt:, verification:, error:, stage_timings:)
      Rails.logger.error(JSON.generate({
        event: "verifier_v2_error",
        label_application_id: application.id,
        verification_attempt_id: attempt.id,
        verification_id: verification.id,
        error_class: error.class.name,
        error_message: redact(error.message.to_s).first(500),
        stage_ms: stage_timings
      }))
    end

    def redact(text)
      SENSITIVE_PATTERNS.reduce(text.to_s) do |memo, pattern|
        memo.gsub(pattern) do
          Regexp.last_match.size > 1 ? "#{Regexp.last_match(1)}[REDACTED]" : "[REDACTED]"
        end
      end
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
