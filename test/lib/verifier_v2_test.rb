# frozen_string_literal: true

require "test_helper"

class VerifierV2Test < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  STATUTORY = Rules::Data.statutory_warning_text

  class StubOcrEngine
    attr_reader :calls

    def initialize(pages:, error: nil)
      @pages = pages
      @error = error
      @calls = 0
    end

    def read(data:, content_type:)
      @calls += 1
      raise @error if @error

      @pages
    end
  end

  class StubAdjudicator
    attr_reader :calls

    def initialize(results:)
      @results = results
      @calls = []
    end

    def adjudicate(fields:, image:, content_type:)
      @calls << { fields: fields, image: image, content_type: content_type }
      @results
    end
  end

  class ImageAwareAdjudicator
    attr_reader :calls

    def initialize(results_by_image:)
      @results_by_image = results_by_image
      @calls = []
    end

    def adjudicate(fields:, image:, content_type:)
      @calls << { fields: fields, image: image, content_type: content_type }
      @results_by_image.fetch(image)
    end
  end

  def create_application(attrs)
    app = LabelApplication.new({
      serial_number: "V2-1",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL",
      declared_class_type: "Kentucky Straight Bourbon Whiskey"
    }.merge(attrs))
    app.artwork.attach(io: StringIO.new("label-bytes"), filename: "label.png", content_type: "image/png")
    app.save!
    app
  end

  def attach_back_artwork(app, bytes)
    app.back_artwork.attach(io: StringIO.new(bytes), filename: "back.png", content_type: "image/png")
    app
  end

  def word(text, x, y, width, height, confidence)
    Extraction::OcrClient.build_word(
      text: text,
      x: x,
      y: y,
      width: width,
      height: height,
      confidence: confidence
    )
  end

  def page(words)
    Extraction::OcrClient::Page.new(number: 1, width: 900, height: 1200, words: words)
  end

  def complete_page
    page([
      word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0),
      word("Kentucky Straight Bourbon Whiskey", 100, 140, 320, 24, 94.0),
      word("45% ALC./VOL. (90 PROOF)", 100, 190, 250, 24, 94.0),
      word("750 mL", 100, 240, 80, 24, 94.0),
      word("DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO.", 100, 290, 500, 24, 94.0),
      word("BARDSTOWN KY", 100, 320, 170, 24, 94.0),
      word(STATUTORY, 100, 850, 600, 120, 94.0)
    ])
  end

  def runner(ocr_engine, adjudicator, vlm_provider: nil, vlm_model: nil)
    VerifierV2::Runner.new(
      ocr_engine: ocr_engine,
      ocr_engine_key: "test-ocr-v1",
      escalation_engine: ocr_engine,
      vlm_adjudicator: adjudicator,
      vlm_provider: vlm_provider,
      vlm_model: vlm_model,
      progress_reporter: VerifierV2::ProgressReporter,
      ocr_readiness: -> {
        Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 1, error_message: nil)
      },
      config: Rails.application.config.x.extraction
    )
  end

  def runner_with_ocr_readiness(ocr_engine, adjudicator, readiness)
    VerifierV2::Runner.new(
      ocr_engine: ocr_engine,
      ocr_engine_key: "test-ocr-v1",
      escalation_engine: ocr_engine,
      vlm_adjudicator: adjudicator,
      vlm_provider: nil,
      vlm_model: nil,
      progress_reporter: VerifierV2::ProgressReporter,
      ocr_readiness: -> { readiness },
      config: Rails.application.config.x.extraction
    )
  end

  def with_verifier_build_dependencies(enriched_engine:, fast_engine:, enriched_key:, fast_key:, adjudicator:)
    original_build = Extraction::OcrFactory.method(:build)
    original_build_fast = Extraction::OcrFactory.method(:build_fast)
    original_cache_key = Extraction::OcrFactory.method(:cache_key)
    original_fast_cache_key = Extraction::OcrFactory.method(:fast_cache_key)
    original_adjudicator = Extraction::VlmAdjudicator.method(:build_for)

    Extraction::OcrFactory.define_singleton_method(:build) { enriched_engine }
    Extraction::OcrFactory.define_singleton_method(:build_fast) { fast_engine }
    Extraction::OcrFactory.define_singleton_method(:cache_key) { enriched_key }
    Extraction::OcrFactory.define_singleton_method(:fast_cache_key) { fast_key }
    Extraction::VlmAdjudicator.define_singleton_method(:build_for) do |provider:, model:|
      raise ArgumentError, "provider is required" if provider.blank?
      raise ArgumentError, "model is required" if model.blank?

      adjudicator
    end

    yield
  ensure
    Extraction::OcrFactory.define_singleton_method(:build, original_build)
    Extraction::OcrFactory.define_singleton_method(:build_fast, original_build_fast)
    Extraction::OcrFactory.define_singleton_method(:cache_key, original_cache_key)
    Extraction::OcrFactory.define_singleton_method(:fast_cache_key, original_fast_cache_key)
    Extraction::VlmAdjudicator.define_singleton_method(:build_for, original_adjudicator)
  end

  test "build wires primary OCR to the strict single-pass engine and cache key" do
    enriched_engine = Object.new
    fast_engine = Object.new
    adjudicator = StubAdjudicator.new(results: [])

    verifier = with_verifier_build_dependencies(
      enriched_engine: enriched_engine,
      fast_engine: fast_engine,
      enriched_key: "tesseract-enriched-v3",
      fast_key: "tesseract-strict-single-pass-v2",
      adjudicator: adjudicator
    ) do
      VerifierV2.build(provider: "openai", model: "gpt-5.4-mini")
    end

    assert_same fast_engine, verifier.instance_variable_get(:@ocr_engine)
    assert_equal "tesseract-strict-single-pass-v2", verifier.instance_variable_get(:@ocr_engine_key)
    assert_same fast_engine, verifier.instance_variable_get(:@escalation_engine)
  end

  test "grounded path persists verification and completes the attempt" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ complete_page ])
    adjudicator = StubAdjudicator.new(results: [])

    verification = runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")

    assert_predicate verification, :needs_review?
    assert_equal VerifierV2::MODEL_ID, verification.model_id
    assert_equal "ocr", verification.extraction.dig("fields", "brand_name", "bbox_source")
    assert_predicate attempt.reload, :needs_review?
    assert_equal verification, attempt.verification
    assert_operator attempt.stage_timings.fetch("ocr_ms"), :>=, 0
    assert_operator attempt.stage_timings.fetch("rules_ms"), :>=, 0
    assert_operator attempt.stage_timings.fetch("persistence_ms"), :>=, 0
    assert_operator attempt.stage_timings.fetch("total_ms"), :>=, 0
  end

  test "ocr operational failure records error attempt without compliance findings" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [], error: Extraction::OcrError.new("tesseract timed out"))
    adjudicator = StubAdjudicator.new(results: [])

    verification = runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")

    assert_predicate verification, :error?
    assert_empty verification.field_checks
    assert_predicate attempt.reload, :error?
    assert_equal "Extraction::OcrError", attempt.error_class
    assert_match(/tesseract timed out/, attempt.error_message)
    assert_equal "tesseract", attempt.error_context.fetch("ocr_engine")
  end

  test "ocr readiness failure records an operational error before OCR reads" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ complete_page ])
    adjudicator = StubAdjudicator.new(results: [])
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(
      ready: false,
      latency_ms: 5,
      error_message: "Tesseract OCR CLI is missing from PATH"
    )

    verification = runner_with_ocr_readiness(ocr, adjudicator, readiness).verify(
      label_application: application,
      attempt: attempt,
      mode: "verifier_v2"
    )

    assert_predicate verification, :error?
    assert_equal 0, ocr.calls
    assert_predicate attempt.reload, :error?
    assert_match(/Tesseract OCR CLI/, attempt.error_message)
    assert_operator attempt.stage_timings.fetch("ocr_readiness_ms"), :>=, 0
  end

  test "error context redacts provider credentials" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(
      pages: [],
      error: Extraction::OcrError.new("api_key='credential' failed")
    )
    adjudicator = StubAdjudicator.new(results: [])

    runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")

    assert_match(/\[REDACTED\]/, attempt.reload.error_context.fetch("error_message"))
    assert_no_match(/credential/, attempt.error_context.fetch("error_message"))
    assert_equal "test-ocr-v1", attempt.error_context.fetch("ocr_version")
  end

  test "unresolved fields are sent to the mini-model adjudicator without changing observed text" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([ word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0) ]) ])
    result = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "ambiguous",
      page: 1,
      reason: "not readable",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = StubAdjudicator.new(results: [ result ])

    verification = runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")

    assert_predicate verification, :fail?
    assert_equal 1, adjudicator.calls.size
    fields = adjudicator.calls.first.fetch(:fields).map(&:name)
    assert_includes fields, "government_warning_text"
    assert_equal "gpt-5.4-mini", verification.extraction.dig("vlm_adjudications", 0, "model_id")
    assert_not verification.extraction.dig("vlm_adjudications", 0).key?("bbox")
    assert_nil verification.extraction.dig("fields", "government_warning")
  end

  test "OCR-only mode persists unresolved OCR findings without VLM adjudication" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([ word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0) ]) ])
    present = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "present",
      page: 1,
      reason: "warning is visible",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = StubAdjudicator.new(results: [ present ])

    verification = runner(ocr, adjudicator).verify(
      label_application: application,
      attempt: attempt,
      mode: "ocr_only"
    )

    assert_predicate verification, :fail?
    assert_empty adjudicator.calls
    assert_nil verification.extraction["vlm_refinement"]
    assert_nil verification.extraction["vlm_adjudications"]
  end

  test "progressive mode persists OCR findings and enqueues VLM refinement for unresolved fields" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([ word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0) ]) ])
    adjudicator = StubAdjudicator.new(results: [])
    verification = nil

    assert_enqueued_jobs 1, only: RefineVerificationJob do
      verification = runner(ocr, adjudicator).verify(
        label_application: application,
        attempt: attempt,
        mode: "ocr_then_vlm"
      )
    end

    assert_predicate verification, :fail?
    assert_empty adjudicator.calls
    assert_equal "pending", verification.extraction.dig("vlm_refinement", "status")
    assert_includes verification.extraction.dig("vlm_refinement", "fields"), "government_warning_text"
    assert_not_includes verification.extraction.dig("vlm_refinement", "fields"), "brand_name"
    refinement_job = enqueued_jobs.find { |job| job.fetch(:job) == RefineVerificationJob }
    assert_equal [ verification.id, nil, nil ], refinement_job.fetch(:args)
  end

  test "progressive mode carries the selected refinement model into the background job" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([ word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0) ]) ])
    adjudicator = StubAdjudicator.new(results: [])
    verification = nil

    assert_enqueued_jobs 1, only: RefineVerificationJob do
      verification = runner(ocr, adjudicator, vlm_provider: "anthropic", vlm_model: "claude-haiku-4-5").verify(
        label_application: application,
        attempt: attempt,
        mode: "ocr_then_vlm"
      )
    end

    assert_equal "anthropic", verification.extraction.dig("vlm_refinement", "provider")
    assert_equal "claude-haiku-4-5", verification.extraction.dig("vlm_refinement", "model")
    refinement_job = enqueued_jobs.find { |job| job.fetch(:job) == RefineVerificationJob }
    assert_equal [ verification.id, "anthropic", "claude-haiku-4-5" ], refinement_job.fetch(:args)
  end

  test "progressive mode records the selected refinement model when VLM has nothing to refine" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [])
    adjudicator = StubAdjudicator.new(results: [])
    verifier = runner(ocr, adjudicator, vlm_provider: "anthropic", vlm_model: "claude-haiku-4-5")
    evaluation = VerifierV2::Runner::Evaluation.new(facts: nil, checks: [], overall_verdict: "pass")
    verification = nil

    assert_no_enqueued_jobs only: RefineVerificationJob do
      verification = verifier.send(
        :persist_ocr_evaluation,
        application: application,
        raw: { "fields" => {} },
        evaluation: evaluation,
        started: Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond),
        stage_timings: {},
        attempt: attempt,
        mode: "ocr_then_vlm"
      )
    end

    assert_equal "skipped", verification.extraction.dig("vlm_refinement", "status")
    assert_equal [], verification.extraction.dig("vlm_refinement", "fields")
    assert_equal "anthropic", verification.extraction.dig("vlm_refinement", "provider")
    assert_equal "claude-haiku-4-5", verification.extraction.dig("vlm_refinement", "model")
  end

  test "present adjudication downgrades unresolved OCR failure to pass with note" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([
      word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0),
      word("Kentucky Straight Bourbon Whiskey", 100, 140, 320, 24, 94.0),
      word("45% ALC./VOL. (90 PROOF)", 100, 190, 250, 24, 94.0),
      word("750 mL", 100, 240, 80, 24, 94.0),
      word("DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO.", 100, 290, 500, 24, 94.0),
      word("BARDSTOWN KY", 100, 320, 170, 24, 94.0),
      word("GOVERNMENT WARMING garbled OCR", 100, 850, 300, 40, 60.0)
    ]) ])
    result = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "present",
      page: 1,
      reason: "warning statement is visible",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = StubAdjudicator.new(results: [ result ])

    verification = runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")
    warning_check = verification.field_checks.find { |check| check.field == "government_warning_text" }
    adjudicated_fields = adjudicator.calls.first.fetch(:fields).map(&:name)

    assert_includes adjudicated_fields, "government_warning_text"
    assert_equal "pass_with_note", warning_check.verdict
    assert_match(/VLM confirmed/, warning_check.note)
    assert_equal "VLM present", warning_check.extracted
  end

  test "refinement updates only unresolved fields confirmed present by VLM" do
    application = create_application({})
    pass_check = FieldCheck.new(
      field: "brand_name",
      verdict: "pass",
      expected: "OLD TOM DISTILLERY",
      extracted: "OLD TOM DISTILLERY",
      citation: "BAM Vol 2 1-1",
      note: nil
    )
    fail_check = FieldCheck.new(
      field: "government_warning_text",
      verdict: "fail",
      expected: STATUTORY,
      extracted: nil,
      citation: "27 CFR 16.21",
      note: "Warning text was not found by OCR"
    )
    verification = application.verifications.create!(
      overall_verdict: "fail",
      field_checks: [ pass_check, fail_check ],
      extraction: { "fields" => {}, "vlm_refinement" => { "status" => "pending" } },
      model_id: VerifierV2::MODEL_ID
    )
    ocr = StubOcrEngine.new(pages: [])
    result = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "present",
      page: 1,
      reason: "warning statement is visible",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = StubAdjudicator.new(results: [ result ])

    runner(ocr, adjudicator).refine_verification(verification: verification)

    checks = verification.reload.field_checks.index_by(&:field)
    assert_equal "pass", checks.fetch("brand_name").verdict
    assert_equal "pass_with_note", checks.fetch("government_warning_text").verdict
    assert_equal [ [ "government_warning_text" ] ], adjudicator.calls.map { |call| call.fetch(:fields).map(&:name) }
    assert_equal "complete", verification.extraction.dig("vlm_refinement", "status")
    assert_equal "present", verification.extraction.dig("vlm_adjudications", 0, "status")
  end

  test "refinement keeps OCR finding when VLM cannot confirm the field" do
    application = create_application({})
    fail_check = FieldCheck.new(
      field: "government_warning_text",
      verdict: "fail",
      expected: STATUTORY,
      extracted: nil,
      citation: "27 CFR 16.21",
      note: "Warning text was not found by OCR"
    )
    verification = application.verifications.create!(
      overall_verdict: "fail",
      field_checks: [ fail_check ],
      extraction: { "fields" => {}, "vlm_refinement" => { "status" => "pending" } },
      model_id: VerifierV2::MODEL_ID
    )
    ocr = StubOcrEngine.new(pages: [])
    result = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "ambiguous",
      page: 1,
      reason: "not readable",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = StubAdjudicator.new(results: [ result ])

    runner(ocr, adjudicator).refine_verification(verification: verification)

    warning_check = verification.reload.field_checks.find { |check| check.field == "government_warning_text" }
    assert_equal "fail", warning_check.verdict
    assert_nil warning_check.extracted
    assert_equal "complete", verification.extraction.dig("vlm_refinement", "status")
    assert_equal "ambiguous", verification.extraction.dig("vlm_adjudications", 0, "status")
  end

  test "present adjudication can come from the back artwork" do
    application = attach_back_artwork(create_application({}), "back-label-bytes")
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([
      word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0),
      word("Kentucky Straight Bourbon Whiskey", 100, 140, 320, 24, 94.0),
      word("45% ALC./VOL. (90 PROOF)", 100, 190, 250, 24, 94.0),
      word("750 mL", 100, 240, 80, 24, 94.0)
    ]) ])
    absent = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "absent",
      page: 1,
      reason: "front panel only",
      model_id: "gpt-5.4-mini"
    )
    present = Extraction::VlmAdjudicator::Result.new(
      field: "government_warning_text",
      status: "present",
      page: 2,
      reason: "warning statement is visible on the back label",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = ImageAwareAdjudicator.new(
      results_by_image: {
        "label-bytes" => [ absent ],
        "back-label-bytes" => [ present ]
      }
    )

    verification = runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")
    warning_check = verification.field_checks.find { |check| check.field == "government_warning_text" }

    assert_equal 2, adjudicator.calls.size
    assert_equal "pass_with_note", warning_check.verdict
    assert_match(/back label/, warning_check.note)
  end

  test "fanciful name receives adjudication budget before lower-priority unresolved fields" do
    fields = %w[
      government_warning_text government_warning_prefix net_contents alcohol_content
      name_and_address brand_name fanciful_name
    ].map do |name|
      Extraction::VlmAdjudicator::Field.new(
        name: name,
        expected_text: "expected #{name}",
        bbox_hint: nil,
        page: 1
      )
    end

    prioritized = runner(StubOcrEngine.new(pages: []), StubAdjudicator.new(results: []))
                  .send(:prioritize_adjudication_fields, fields)
                  .first(VerifierV2::VLM_FIELD_LIMIT)
                  .map(&:name)

    assert_includes prioritized, "fanciful_name"
  end

  test "alcohol content adjudication can confirm a generic statement when application abv is blank" do
    application = create_application({ alcohol_content: nil })
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ page([
      word("OLD TOM DISTILLERY", 100, 80, 240, 40, 95.0),
      word("Kentucky Straight Bourbon Whiskey", 100, 140, 320, 24, 94.0),
      word("750 mL", 100, 240, 80, 24, 94.0)
    ]) ])
    result = Extraction::VlmAdjudicator::Result.new(
      field: "alcohol_content",
      status: "present",
      page: 1,
      reason: "an ABV statement is visible",
      model_id: "gpt-5.4-mini"
    )
    adjudicator = StubAdjudicator.new(results: [ result ])

    verification = runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")
    alcohol_check = verification.field_checks.find { |check| check.field == "alcohol_content" }

    assert_equal "pass_with_note", alcohol_check.verdict
    assert_match(/ABV statement/, alcohol_check.note)
  end

  test "emits progress stage notifications" do
    application = create_application({})
    attempt = application.verification_attempts.create!
    ocr = StubOcrEngine.new(pages: [ complete_page ])
    adjudicator = StubAdjudicator.new(results: [])
    events = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      events << payload
    end

    ActiveSupport::Notifications.subscribed(subscriber, VerifierV2::ProgressReporter::EVENT_NAME) do
      runner(ocr, adjudicator).verify(label_application: application, attempt: attempt, mode: "verifier_v2")
    end

    assert_includes events.map { |event| event.fetch(:event) }, "stage_started"
    assert_includes events.map { |event| event.fetch(:event) }, "stage_finished"
    assert_includes events.map { |event| event.fetch(:stage) }, "ocr_ms"
  end
end
