# frozen_string_literal: true

require "test_helper"

class VerifyLabelJobTest < ActiveSupport::TestCase
  STATUTORY = Rules::Data.statutory_warning_text

  class StubExtractor
    attr_reader :calls, :model_id

    def initialize(payload:, error: nil, model_id: "stub-model")
      @payload = payload
      @error = error
      @model_id = model_id
      @calls = 0
    end

    def extract(artworks:)
      @calls += 1
      raise @error if @error

      LabelExtractor::Result.new(
        facts: Extraction::FactsMapper.to_facts(@payload),
        raw: @payload,
        model_id: @model_id,
        latency_ms: 12
      )
    end
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
    app = LabelApplication.new({
      serial_number: "26-1042",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    }.merge(attrs))
    app.artwork.attach(io: StringIO.new(attrs[:artwork_bytes] || "label-bytes"),
                       filename: "label.png", content_type: "image/png")
    app.save!
    app
  end

  class StubOcr
    def initialize(pages: [], error: nil)
      @pages = pages
      @error = error
    end

    def read(data:, content_type:)
      raise @error if @error

      @pages
    end
  end

  # Keep the suite off the real tesseract binary: an empty OCR read means
  # every field falls back to the model's box.
  setup do
    @original_ocr_factory = VerifyLabelJob.ocr_factory
    VerifyLabelJob.ocr_factory = -> { StubOcr.new }
  end

  teardown do
    VerifyLabelJob.ocr_factory = @original_ocr_factory
  end

  def with_extractor(stub)
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = ->(_provider, _model) { stub }
    yield
  ensure
    VerifyLabelJob.extractor_factory = original
  end

  def with_ocr(stub)
    original = VerifyLabelJob.ocr_factory
    VerifyLabelJob.ocr_factory = -> { stub }
    yield
  ensure
    VerifyLabelJob.ocr_factory = original
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
    assert verification.field_checks.any? { |c| c.field == "government_warning_text" && c.verdict == "pass" }
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

  test "OCR grounding re-anchors matchable boxes and records provenance" do
    app = create_application({})
    words = [
      Extraction::OcrClient::Word.new(text: "OLD", x: 100, y: 80, width: 60, height: 40),
      Extraction::OcrClient::Word.new(text: "TOM", x: 170, y: 80, width: 70, height: 40),
      Extraction::OcrClient::Word.new(text: "DISTILLERY", x: 250, y: 80, width: 200, height: 42)
    ]
    page = Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)

    verification = with_ocr(StubOcr.new(pages: [ page ])) do
      with_extractor(StubExtractor.new(payload: payload({}))) { VerifyLabelJob.perform_now(app.id) }
    end

    brand = verification.extraction.dig("fields", "brand_name")
    assert_equal [ 100, 80, 350, 42 ], brand["bbox"]
    assert_equal [ 800, 1000 ], brand["bbox_basis"]
    assert_equal "ocr", brand["bbox_source"]
    assert_equal "model", verification.extraction.dig("fields", "government_warning", "bbox_source")
  end

  test "OCR failure keeps the model's boxes and still completes verification" do
    app = create_application({})
    failing_ocr = StubOcr.new(error: Extraction::OcrError.new("tesseract is not installed"))

    verification = with_ocr(failing_ocr) do
      with_extractor(StubExtractor.new(payload: payload({}))) { VerifyLabelJob.perform_now(app.id) }
    end

    assert_predicate verification, :pass?
    brand = verification.extraction.dig("fields", "brand_name")
    assert_equal [ 1, 2, 3, 4 ], brand["bbox"]
    assert_nil brand["bbox_source"]
  end

  test "fanciful name reconciles to the declared value located by OCR" do
    app = create_application(fanciful_name: "DRAUGHT STOUT")
    tagline = { "text" => "Lovely Day for a Guinness", "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.85 }
    words = [
      Extraction::OcrClient::Word.new(text: "DRAUGHT", x: 300, y: 500, width: 90, height: 30),
      Extraction::OcrClient::Word.new(text: "STOUT", x: 400, y: 500, width: 70, height: 30)
    ]
    page = Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)

    verification = with_ocr(StubOcr.new(pages: [ page ])) do
      with_extractor(StubExtractor.new(payload: payload("fields" => payload({})["fields"].merge("fanciful_name" => tagline)))) do
        VerifyLabelJob.perform_now(app.id)
      end
    end

    fanciful = verification.extraction.dig("fields", "fanciful_name")
    assert_equal "DRAUGHT STOUT", fanciful["text"]
    assert_equal "ocr", fanciful["bbox_source"]
    check = verification.field_checks.find { |c| c.field == "fanciful_name" }
    assert_equal "pass", check.verdict
  end

  test "several unreadable mandatory fields add an artwork-quality advisory" do
    app = create_application({})
    sparse = payload({})
    sparse["fields"] = sparse["fields"].merge(
      "name_address_statement" => nil, "government_warning" => nil, "net_contents" => nil
    )

    verification = with_extractor(StubExtractor.new(payload: sparse)) { VerifyLabelJob.perform_now(app.id) }

    advisory = verification.field_checks.find { |c| c.field == "artwork_quality" }
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
    note = verification.field_checks.find { |c| c.field == "duplicate_artwork" }
    assert_not_nil note
    assert_match(/26-1042/, note.note)
  end

  include ActiveJob::TestHelper

  test "extraction errors are recorded as retryable error verifications" do
    app = create_application({})
    stub = StubExtractor.new(payload: nil, error: Extraction::ExtractionError.new("API unavailable"))

    with_extractor(stub) do
      # retry_on captures the error and re-enqueues rather than raising.
      assert_enqueued_with(job: VerifyLabelJob) { VerifyLabelJob.perform_now(app.id) }
    end

    # ActiveJob's retry_on handler runs only through the enqueue cycle; the
    # direct record path is what the handler calls.
    VerifyLabelJob.new.send(:record_error, app, Extraction::ExtractionError.new("API unavailable"))
    error_verification = app.verifications.error.last
    assert_not_nil error_verification
    assert_match(/API unavailable/, error_verification.error_message)
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
