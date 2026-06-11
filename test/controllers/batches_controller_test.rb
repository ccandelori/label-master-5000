# frozen_string_literal: true

require "test_helper"

class BatchesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  STATUTORY = Rules::Data.statutory_warning_text

  class StubExtractor
    def model_id
      "stub-model"
    end

    def extract(data:, content_type:)
      brand = data.include?("alpha") ? "ALPHA ALE" : "BETA BOURBON"
      payload = {
        "legible" => true,
        "confidence" => 0.95,
        "fields" => {
          "brand_name" => { "text" => brand, "bbox" => [ 1, 1, 10, 5 ], "page" => 1, "confidence" => 0.9 },
          "fanciful_name" => nil,
          "class_type_designation" => { "text" => data.include?("alpha") ? "India Pale Ale" : "Straight Bourbon Whiskey", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "alcohol_statement" => { "text" => data.include?("alpha") ? "6.5% ALC/VOL" : "45% ALC./VOL.", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "net_contents" => { "text" => data.include?("alpha") ? "12 fl oz" : "750 mL", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "name_address_statement" => { "text" => data.include?("alpha") ? "BREWED AND BOTTLED BY ALPHA BREWING, PORTLAND, OR" : "DISTILLED AND BOTTLED BY BETA DISTILLING, FRANKFORT, KY", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "country_of_origin_statement" => nil,
          "government_warning" => { "text" => STATUTORY, "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "commodity_statement" => nil,
          "appellation" => nil,
          "vintage" => nil
        },
        "varietals" => [],
        "disclosures" => [],
        "warning_attributes" => { "prefix_all_caps" => true, "prefix_bold" => true, "continuous_paragraph" => true }
      }
      LabelExtractor::Result.new(
        facts: Extraction::FactsMapper.to_facts(payload), raw: payload,
        model_id: "stub", latency_ms: 40
      )
    end
  end

  CSV_TEXT = <<~CSV
    serial_number,beverage_type,brand_name,applicant_name_address,alcohol_content,net_contents,image_filename
    26-1,malt,ALPHA ALE,"Alpha Brewing, Portland, OR",6.5,12 fl oz,alpha.png
    26-2,spirits,BETA BOURBON,"Beta Distilling, Frankfort, KY",45,750 mL,beta.png
  CSV

  def upload_csv(text)
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "batch.csv")
  end

  def upload_image(name)
    Rack::Test::UploadedFile.new(StringIO.new("#{name.split('.').first}-bytes"), "image/png", original_filename: name)
  end

  def create_clean_batch
    with_stub_extractor do
      perform_enqueued_jobs do
        post batches_path, params: {
          batch: { name: "June shipment", csv_file: upload_csv(CSV_TEXT),
                   images: [ upload_image("alpha.png"), upload_image("beta.png") ] }
        }
      end
    end
    Batch.last
  end

  def with_stub_extractor
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = -> { StubExtractor.new }
    yield
  ensure
    VerifyLabelJob.extractor_factory = original
  end

  test "a clean batch creates applications, runs them, and shows results" do
    batch = create_clean_batch

    assert_equal 2, batch.label_applications.count
    assert_equal 2, batch.done_count

    get batch_path(batch)
    assert_response :success
    assert_match(/2 of 2 checked/, response.body)
    assert_match(/ALPHA ALE/, response.body)
  end

  test "validation failures start nothing" do
    bad_csv = CSV_TEXT.sub("alpha.png", "missing.png")
    assert_no_enqueued_jobs do
      post batches_path, params: {
        batch: { csv_file: upload_csv(bad_csv),
                 images: [ upload_image("alpha.png"), upload_image("beta.png") ] }
      }
    end
    assert_response :unprocessable_entity
    assert_match(/no uploaded image named missing.png/, response.body)
    assert_equal 0, Batch.count
  end

  test "missing files are a clear error" do
    post batches_path, params: { batch: { name: "Empty" } }
    assert_response :unprocessable_entity
    assert_match(/CSV file is required/, response.body)
  end

  test "verdict filter narrows the rows" do
    batch = create_clean_batch
    get batch_path(batch, verdict: "fail")
    assert_response :success
    assert_no_match(/ALPHA ALE/, response.body)
  end

  test "retry_failed re-enqueues only error rows" do
    batch = create_clean_batch
    failed_application = batch.label_applications.first
    VerifyLabelJob.new.send(:record_error, failed_application, Extraction::ExtractionError.new("boom"))

    assert_enqueued_jobs 1, only: VerifyLabelJob do
      post retry_failed_batch_path(batch)
    end
  end

  test "batch uploads create pre-review records that bulk-submit to TTB" do
    batch = create_clean_batch
    assert batch.label_applications.all?(&:pre_review?)

    post batch_submission_path(batch)
    assert_redirected_to batch_path(batch)
    assert_match(/Submitted 2 applications/, flash[:notice])
    assert batch.label_applications.reload.all?(&:submitted?)

    post batch_submission_path(batch)
    assert_match(/already been submitted/, flash[:alert])
  end

  test "export includes verdicts and cited findings" do
    batch = create_clean_batch
    batch.label_applications.last.latest_verification.record_decision(decision: "approve", note: nil)

    get export_batch_path(batch)
    assert_response :success
    assert_equal "text/csv", response.media_type

    lines = response.body.lines
    assert_match(/row,serial_number,brand_name/, lines.first)
    assert_match(/26-1,ALPHA ALE,malt/, response.body)
    assert_match(/approve/, response.body)
  end
end
