# frozen_string_literal: true

require "test_helper"

class VerifyLabelJobTest < ActiveSupport::TestCase
  STATUTORY = Rules::Data.statutory_warning_text

  class StubExtractor
    attr_reader :calls

    def initialize(payload:, error: nil)
      @payload = payload
      @error = error
      @calls = 0
    end

    def extract(data:, content_type:)
      @calls += 1
      raise @error if @error

      LabelExtractor::Result.new(
        facts: Extraction::FactsMapper.to_facts(@payload),
        raw: @payload,
        model_id: "stub-model",
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

  def with_extractor(stub)
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = -> { stub }
    yield
  ensure
    VerifyLabelJob.extractor_factory = original
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
end
