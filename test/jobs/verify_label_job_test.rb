# frozen_string_literal: true

require "test_helper"

class VerifyLabelJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  STATUTORY = Rules::Data.statutory_warning_text

  class StubExtractor
    attr_reader :calls, :applications, :model_id

    def initialize(payload:, error: nil, model_id: "stub-model")
      @payload = payload
      @error = error
      @model_id = model_id
      @calls = 0
      @applications = []
    end

    def extract(artworks:, application:)
      @calls += 1
      @applications << application
      raise @error if @error

      LabelExtractor::Result.new(
        facts: Extraction::FactsMapper.to_facts(@payload),
        raw: @payload,
        model_id: @model_id,
        latency_ms: 12
      )
    end
  end

  class StubOcrEngine
    attr_reader :calls

    def initialize(pages:)
      @pages = pages
      @calls = 0
    end

    def read(data:, content_type:)
      @calls += 1
      @pages
    end
  end

  def setup
    @original_extraction_mode = Rails.application.config.x.extraction.mode
    Rails.application.config.x.extraction.mode = "vlm"
  end

  def teardown
    Rails.application.config.x.extraction.mode = @original_extraction_mode
  end

  def payload(overrides)
    {
      "legible" => true,
      "confidence" => 0.95,
      "fields" => {
        "brand_name" => { "text" => "OLD TOM DISTILLERY", "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.98 },
        "fanciful_name" => nil,
        "class_type_designation" => { "text" => "Kentucky Straight Bourbon Whiskey", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
        "alcohol_statement" => { "text" => "45% ALC./VOL. (90 PROOF)", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
        "net_contents" => { "text" => "750 mL", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
        "name_address_statement" => { "text" => "DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO., BARDSTOWN, KY", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
        "country_of_origin_statement" => nil,
        "government_warning" => { "text" => STATUTORY, "bbox" => nil, "page" => 1, "confidence" => 0.9 },
        "commodity_statement" => nil,
        "appellation" => nil,
        "vintage" => nil
      },
      "varietals" => [],
      "disclosures" => [],
      "warning_attributes" => { "prefix_all_caps" => true, "prefix_bold" => true, "continuous_paragraph" => true }
    }.merge(overrides)
  end

  def create_application(attrs)
    artwork_bytes = attrs[:artwork_bytes] || "label-bytes"
    app = LabelApplication.new({
      serial_number: "26-1042",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    }.merge(attrs.except(:artwork_bytes)))
    app.artwork.attach(io: StringIO.new(artwork_bytes),
                       filename: "label.png", content_type: "image/png")
    app.save!
    app
  end

  def word(text, x, y, width, height)
    Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: width, height: height)
  end

  def page(words)
    Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)
  end

  def with_extractor(stub)
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = ->(_provider, _model) { stub }
    yield
  ensure
    VerifyLabelJob.extractor_factory = original
  end

  def with_ocr_engine(engine)
    original_factory = VerifyLabelJob.ocr_engine_factory
    original_key_factory = VerifyLabelJob.ocr_engine_key_factory
    VerifyLabelJob.ocr_engine_factory = -> { engine }
    VerifyLabelJob.ocr_engine_key_factory = -> { "test-tesseract-v1" }
    yield
  ensure
    VerifyLabelJob.ocr_engine_factory = original_factory
    VerifyLabelJob.ocr_engine_key_factory = original_key_factory
  end

  def with_ocr_region_engine(engine)
    original_factory = VerifyLabelJob.ocr_region_engine_factory
    VerifyLabelJob.ocr_region_engine_factory = -> { engine }
    yield
  ensure
    VerifyLabelJob.ocr_region_engine_factory = original_factory
  end

  def with_ocr_region_refinement(enabled)
    original = Rails.application.config.x.extraction.ocr_region_refinement
    Rails.application.config.x.extraction.ocr_region_refinement = enabled
    yield
  ensure
    Rails.application.config.x.extraction.ocr_region_refinement = original
  end

  def with_extraction_mode(mode)
    original = Rails.application.config.x.extraction.mode
    Rails.application.config.x.extraction.mode = mode
    yield
  ensure
    Rails.application.config.x.extraction.mode = original
  end

  def with_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original
  end

  def with_verifier_v2(implementation)
    original = VerifierV2.method(:verify)
    VerifierV2.define_singleton_method(:verify, implementation)
    yield
  ensure
    VerifierV2.define_singleton_method(:verify, original)
  end

  test "verification jobs run on the dedicated verification queue" do
    assert_equal "verification", VerifyLabelJob.queue_name
    assert_equal Integer(ENV.fetch("VERIFY_CONCURRENCY", ENV.fetch("OCR_CONCURRENCY", "1"))),
                 VerifyLabelJob.configured_concurrency
  end

  test "default model id comes from the configured extractor" do
    stub = StubExtractor.new(payload: payload({}), model_id: "configured-model")

    assert_equal "configured-model", with_extractor(stub) { VerifyLabelJob.default_model_id }
  end

  test "happy path persists a passing verification with extraction payload" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload({}))

    verification = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_predicate verification, :pass?
    assert_not verification.extraction_reused
    assert_equal "stub-model", verification.model_id
    assert verification.latency_ms >= 0
    assert_equal [ 1, 2, 3, 4 ], verification.extraction.dig("fields", "brand_name", "bbox")
    assert verification.field_checks.any? { |check| check.field == "government_warning_text" && check.verdict == "pass" }
  end

  test "direct verification creates and completes an attempt" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload({}))

    assert_difference -> { app.verification_attempts.count } do
      with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }
    end

    attempt = app.verification_attempts.last
    assert_predicate attempt, :passed?
    assert_not_nil attempt.processing_started_at
    assert_not_nil attempt.processing_completed_at
    assert_equal app.latest_verification, attempt.verification
    assert_operator attempt.stage_timings.fetch("load_application"), :>=, 0
    assert_operator attempt.stage_timings.fetch("verification_persist"), :>=, 0
  end

  test "verification uses the queued admission attempt when provided" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    stub = StubExtractor.new(payload: payload({}))

    assert_no_difference -> { app.verification_attempts.count } do
      with_extractor(stub) { VerifyLabelJob.perform_now(app.id, nil, nil, nil, attempt.id) }
    end

    assert_predicate attempt.reload, :passed?
    assert_equal app.latest_verification, attempt.verification
  end

  test "feature flag routes verification through VerifierV2 with the queued attempt" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    calls = []
    implementation = lambda do |label_application:, attempt:, mode:, provider:, model:|
      calls << [ label_application.id, attempt.id, mode, provider, model ]
      attempt.start_processing! if attempt.queued?
      verification = label_application.verifications.create!(
        overall_verdict: "needs_review",
        field_checks: [],
        model_id: VerifierV2::MODEL_ID
      )
      attempt.finish_with!(verification: verification, stage_timings: { "v2" => 1 })
      verification
    end

    verification = with_env("USE_VERIFIER_V2", "true") do
      with_verifier_v2(implementation) { VerifyLabelJob.perform_now(app.id, nil, nil, nil, attempt.id) }
    end

    assert_equal VerifierV2::MODEL_ID, verification.model_id
    assert_equal [ [ app.id, attempt.id, "verifier_v2", nil, nil ] ], calls
    assert_predicate attempt.reload, :needs_review?
    assert_equal({ "v2" => 1 }, attempt.stage_timings)
  end

  test "explicit verifier v2 mode routes verification through VerifierV2" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    calls = []
    implementation = lambda do |label_application:, attempt:, mode:, provider:, model:|
      calls << [ label_application.id, attempt.id, mode, provider, model ]
      attempt.start_processing! if attempt.queued?
      verification = label_application.verifications.create!(
        overall_verdict: "needs_review",
        field_checks: [],
        model_id: VerifierV2::MODEL_ID
      )
      attempt.finish_with!(verification: verification, stage_timings: { "v2" => 1 })
      verification
    end

    verification = with_verifier_v2(implementation) do
      VerifyLabelJob.perform_now(app.id, nil, nil, "verifier_v2", attempt.id)
    end

    assert_equal VerifierV2::MODEL_ID, verification.model_id
    assert_equal [ [ app.id, attempt.id, "verifier_v2", nil, nil ] ], calls
    assert_predicate attempt.reload, :needs_review?
  end

  test "explicit OCR-only mode routes verification through VerifierV2" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    calls = []
    implementation = lambda do |label_application:, attempt:, mode:, provider:, model:|
      calls << [ label_application.id, attempt.id, mode, provider, model ]
      attempt.start_processing! if attempt.queued?
      verification = label_application.verifications.create!(
        overall_verdict: "fail",
        field_checks: [],
        model_id: VerifierV2::MODEL_ID
      )
      attempt.finish_with!(verification: verification, stage_timings: { "v2" => 1 })
      verification
    end

    verification = with_verifier_v2(implementation) do
      VerifyLabelJob.perform_now(app.id, nil, nil, "ocr_only", attempt.id)
    end

    assert_equal VerifierV2::MODEL_ID, verification.model_id
    assert_equal [ [ app.id, attempt.id, "ocr_only", nil, nil ] ], calls
    assert_predicate attempt.reload, :failed?
  end

  test "explicit OCR then VLM mode routes verification through VerifierV2" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    calls = []
    implementation = lambda do |label_application:, attempt:, mode:, provider:, model:|
      calls << [ label_application.id, attempt.id, mode, provider, model ]
      attempt.start_processing! if attempt.queued?
      verification = label_application.verifications.create!(
        overall_verdict: "needs_review",
        field_checks: [],
        model_id: VerifierV2::MODEL_ID
      )
      attempt.finish_with!(verification: verification, stage_timings: { "v2" => 1 })
      verification
    end

    verification = with_verifier_v2(implementation) do
      VerifyLabelJob.perform_now(app.id, nil, nil, "ocr_then_vlm", attempt.id)
    end

    assert_equal VerifierV2::MODEL_ID, verification.model_id
    assert_equal [ [ app.id, attempt.id, "ocr_then_vlm", nil, nil ] ], calls
    assert_predicate attempt.reload, :needs_review?
  end

  test "explicit OCR then VLM mode routes the selected refinement model through VerifierV2" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    calls = []
    implementation = lambda do |label_application:, attempt:, mode:, provider:, model:|
      calls << [ label_application.id, attempt.id, mode, provider, model ]
      attempt.start_processing! if attempt.queued?
      verification = label_application.verifications.create!(
        overall_verdict: "needs_review",
        field_checks: [],
        model_id: VerifierV2::MODEL_ID
      )
      attempt.finish_with!(verification: verification, stage_timings: { "v2" => 1 })
      verification
    end

    with_verifier_v2(implementation) do
      VerifyLabelJob.perform_now(app.id, "anthropic", "claude-haiku-4-5", "ocr_then_vlm", attempt.id)
    end

    assert_equal [ [ app.id, attempt.id, "ocr_then_vlm", "anthropic", "claude-haiku-4-5" ] ], calls
  end

  test "passes the loaded application to the VLM extractor" do
    app = create_application(serial_number: "26-9999", brand_name: "MIA-LOU")
    stub = StubExtractor.new(payload: payload("fields" => payload({})["fields"].merge(
      "brand_name" => { "text" => "MIA-LOU", "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.98 }
    )))

    with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_equal 1, stub.calls
    assert_equal app.id, stub.applications.first.id
    assert_equal "MIA-LOU", stub.applications.first.brand_name
  end

  test "applies VLM reconciliation before rules evaluation" do
    app = create_application({})
    fields = payload({})["fields"].merge(
      "alcohol_statement" => nil,
      "commodity_statement" => { "text" => "45% ALC./VOL. (90 PROOF)", "bbox" => [ 10, 20, 140, 24 ], "page" => 1, "confidence" => 0.9 }
    )
    stub = StubExtractor.new(payload: payload("fields" => fields))

    verification = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_predicate verification, :pass?
    alcohol = verification.extraction.dig("fields", "alcohol_statement")
    assert_equal "45% ALC./VOL. (90 PROOF)", alcohol["text"]
    assert_equal "vlm_reconciled", alcohol["source"]
    assert verification.field_checks.any? { |check| check.field == "alcohol_content" && check.verdict == "pass" }
  end

  test "quality mode persists clean Tesseract OCR without calling the VLM" do
    app = create_application(declared_class_type: "Kentucky Straight Bourbon Whiskey")
    ocr = StubOcrEngine.new(pages: [ page([
      word("OLD TOM DISTILLERY", 100, 80, 220, 40),
      word("Kentucky Straight Bourbon Whiskey", 100, 140, 300, 24),
      word("45% ALC./VOL. (90 PROOF)", 100, 180, 240, 24),
      word("750 mL", 100, 220, 80, 24),
      word("DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO.", 100, 260, 420, 24),
      word("BARDSTOWN KY", 100, 290, 160, 24),
      word(STATUTORY, 100, 700, 560, 80)
    ]) ])
    extractor = StubExtractor.new(payload: payload({}), error: Extraction::ExtractionError.new("VLM should not run"))

    verification = with_extraction_mode("quality") do
      with_ocr_engine(ocr) do
        with_extractor(extractor) { VerifyLabelJob.perform_now(app.id) }
      end
    end

    assert_equal 0, extractor.calls
    assert_equal 1, ocr.calls
    assert_equal "quality-v1", verification.model_id
    assert_equal "ocr", verification.extraction.dig("fields", "government_warning", "bbox_source")
    assert verification.field_checks.none? { |check| check.verdict == "fail" }
  end

  test "quality mode falls back to VLM and OCR-grounds the model result when OCR is incomplete" do
    app = create_application({})
    ocr = StubOcrEngine.new(pages: [ page([
      word("OLD", 100, 80, 60, 40),
      word("TOM", 170, 80, 70, 40),
      word("DISTILLERY", 250, 80, 160, 40)
    ]) ])
    extractor = StubExtractor.new(payload: payload({}), model_id: "stub-vlm")

    verification = with_extraction_mode("quality") do
      with_ocr_engine(ocr) do
        with_extractor(extractor) { VerifyLabelJob.perform_now(app.id) }
      end
    end

    assert_equal 1, extractor.calls
    assert_equal "quality-v1", verification.model_id
    assert_equal "OLD TOM DISTILLERY", verification.extraction.dig("fields", "brand_name", "text")
    assert_equal "ocr", verification.extraction.dig("fields", "brand_name", "bbox_source")
    assert_equal [ 100, 80, 310, 40 ], verification.extraction.dig("fields", "brand_name", "bbox")
  end

  test "quality mode fallback skips region crop OCR by default" do
    app = create_application({})
    page_ocr = StubOcrEngine.new(pages: [ page([]) ])
    region_ocr = StubOcrEngine.new(pages: [ page([ word("OLD TOM DISTILLERY", 100, 80, 220, 40) ]) ])
    extractor = StubExtractor.new(payload: payload({}), model_id: "stub-vlm")

    verification = with_extraction_mode("quality") do
      with_ocr_region_refinement(false) do
        with_ocr_engine(page_ocr) do
          with_ocr_region_engine(region_ocr) do
            with_extractor(extractor) { VerifyLabelJob.perform_now(app.id) }
          end
        end
      end
    end

    assert_equal 1, extractor.calls
    assert_equal 0, region_ocr.calls
    assert_equal "model", verification.extraction.dig("fields", "brand_name", "bbox_source")
  end

  test "emits stage timing events for the VLM-only pipeline" do
    app = create_application(artwork_bytes: "timed-label-bytes")
    stub = StubExtractor.new(payload: payload({}))
    events = []
    subscriber = lambda do |name, started, finished, _id, event_payload|
      events << event_payload.merge(event: name, duration_ms: ((finished - started) * 1000.0).round(2))
    end

    ActiveSupport::Notifications.subscribed(subscriber, "verification.stage.label_verifier") do
      with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }
    end

    stages = events.map { |event| event[:stage] }
    assert_includes stages, "vlm_extraction"
    assert_includes stages, "vlm_reconciliation"
    assert_includes stages, "facts_mapping"
    assert_includes stages, "rules_evaluation"
    assert events.all? { |event| event[:duration_ms] >= 0 }
  end

  test "illegible artwork ends as request_retake with no field verdicts" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload("legible" => false, "confidence" => 0.2))

    verification = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_predicate verification, :request_retake?
    assert_empty verification.field_checks
  end

  test "low confidence triggers the retake gate even when nominally legible" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload("confidence" => 0.3))

    verification = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_predicate verification, :request_retake?
  end

  test "re-verification reuses the cached extraction without calling the extractor" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload({}))

    first = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }
    assert_equal 1, stub.calls

    app.update!(alcohol_content: 40.0)
    second = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_equal 1, stub.calls, "extractor must not be called again for the same blob"
    assert second.extraction_reused
    assert_predicate second, :fail?
    assert_equal first.extraction, second.extraction
    assert_equal 2, app.verifications.count, "history must be preserved"
  end

  test "a different model never reuses another model's extraction" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload({}))

    with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }
    assert_equal 1, stub.calls

    other_model = StubExtractor.new(payload: payload({}), model_id: "other-model")
    second = with_extractor(other_model) { VerifyLabelJob.perform_now(app.id) }

    assert_equal 1, other_model.calls, "a model must produce its own reading"
    assert_not second.extraction_reused
    assert_equal "other-model", second.model_id
  end

  test "adding a back label changes the fingerprint and forces a fresh extraction" do
    app = create_application({})
    stub = StubExtractor.new(payload: payload({}))

    first = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }
    assert_equal app.artwork.blob.checksum, first.artwork_fingerprint

    app.back_artwork.attach(io: StringIO.new("back-bytes"), filename: "back.png", content_type: "image/png")
    app.save!
    second = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_equal 2, stub.calls, "the same front with a different back is a different reading"
    assert_not second.extraction_reused
    assert_equal "#{app.artwork.blob.checksum}+#{app.back_artwork.blob.checksum}",
                 second.artwork_fingerprint

    third = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }
    assert_equal 2, stub.calls, "the same pair reuses the pair's extraction"
    assert third.extraction_reused
  end

  test "several unreadable mandatory fields add an artwork-quality advisory" do
    app = create_application({})
    sparse = payload({})
    sparse["fields"] = sparse["fields"].merge(
      "name_address_statement" => nil, "government_warning" => nil, "net_contents" => nil
    )

    verification = with_extractor(StubExtractor.new(payload: sparse)) { VerifyLabelJob.perform_now(app.id) }

    advisory = verification.field_checks.find { |check| check.field == "artwork_quality" }
    assert_not_nil advisory, "expected the extraction-coverage advisory"
    assert_equal "pass_with_note", advisory.verdict
    assert_equal "fail", verification.overall_verdict, "the advisory never outranks the failures that triggered it"
  end

  test "duplicate artwork across applications gets a note" do
    original = create_application(serial_number: "26-1042")
    stub = StubExtractor.new(payload: payload({}))
    with_extractor(stub) { VerifyLabelJob.perform_now(original.id) }

    duplicate = create_application(serial_number: "26-9999")
    verification = with_extractor(stub) { VerifyLabelJob.perform_now(duplicate.id) }

    assert_equal 1, stub.calls
    note = verification.field_checks.find { |check| check.field == "duplicate_artwork" }
    assert_not_nil note
    assert_match(/26-1042/, note.note)
  end

  test "extraction errors are recorded as retryable error verifications" do
    app = create_application({})
    stub = StubExtractor.new(payload: nil, error: Extraction::ExtractionError.new("API unavailable"))

    with_extractor(stub) do
      assert_enqueued_with(job: VerifyLabelJob) { VerifyLabelJob.perform_now(app.id) }
    end

    VerifyLabelJob.new.send(:record_error, app, Extraction::ExtractionError.new("API unavailable"))
    error_verification = app.verifications.error.last
    error_attempt = app.verification_attempts.error.last
    assert_not_nil error_verification
    assert_not_nil error_attempt
    assert_equal error_verification, error_attempt.verification
    assert_match(/API unavailable/, error_verification.error_message)
  end

  test "unexpected errors finish the active attempt as an error" do
    app = create_application({})
    attempt = app.verification_attempts.create!
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = ->(_provider, _model) {
      raise Encoding::CompatibilityError, "Unicode Normalization not appropriate for ASCII-8BIT"
    }

    error = assert_raises(Encoding::CompatibilityError) do
      VerifyLabelJob.perform_now(app.id, nil, nil, "vlm", attempt.id)
    end

    assert_match(/ASCII-8BIT/, error.message)
    assert_predicate attempt.reload, :error?
    assert_not_nil attempt.verification
    assert_equal "error", attempt.verification.overall_verdict
    assert_match(/ASCII-8BIT/, attempt.error_message)
  ensure
    VerifyLabelJob.extractor_factory = original
  end

  test "error verifications never satisfy extraction reuse" do
    app = create_application({})
    VerifyLabelJob.new.send(:record_error, app, Extraction::ExtractionError.new("boom"))

    stub = StubExtractor.new(payload: payload({}))
    verification = with_extractor(stub) { VerifyLabelJob.perform_now(app.id) }

    assert_equal 1, stub.calls
    assert_predicate verification, :pass?
  end

  test "a per-run model override extracts on its own and reuses only within itself" do
    app = create_application({})
    default_stub = StubExtractor.new(payload: payload({}), model_id: "model-default")
    demo_stub = StubExtractor.new(payload: payload({}), model_id: "model-demo")
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = ->(provider, model) do
      assert_includes [ nil, "anthropic" ], provider
      model == "model-demo" ? demo_stub : default_stub
    end

    first = VerifyLabelJob.perform_now(app.id)
    overridden = VerifyLabelJob.perform_now(app.id, "anthropic", "model-demo")
    repeated = VerifyLabelJob.perform_now(app.id, "anthropic", "model-demo")

    assert_equal "model-default", first.model_id
    assert_equal "model-demo", overridden.model_id
    assert_not overridden.extraction_reused, "another model's extraction must not be reused"
    assert repeated.extraction_reused, "the same model's extraction is reused"
    assert_equal 1, demo_stub.calls
  ensure
    VerifyLabelJob.extractor_factory = original
  end
end
