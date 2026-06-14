# frozen_string_literal: true

require "test_helper"

class BatchesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  STATUTORY = Rules::Data.statutory_warning_text

  class StubExtractor
    def model_id
      "stub-model"
    end

    def extract(artworks:, application:)
      data = artworks.first.data
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

  class StubOcrEngine
    def read(data:, content_type:)
      brand = data.include?("alpha") ? "ALPHA ALE" : "BETA BOURBON"
      class_type = data.include?("alpha") ? "India Pale Ale" : "Straight Bourbon Whiskey"
      alcohol = data.include?("alpha") ? "6.5% ALC/VOL" : "45% ALC./VOL."
      net_contents = data.include?("alpha") ? "12 fl oz" : "750 mL"
      name_address = if data.include?("alpha")
        "BREWED AND BOTTLED BY ALPHA BREWING, PORTLAND, OR"
      else
        "DISTILLED AND BOTTLED BY BETA DISTILLING, FRANKFORT, KY"
      end

      words = [
        word(brand, 10, 10),
        word(class_type, 10, 50),
        word(alcohol, 10, 90),
        word(net_contents, 10, 130),
        word(name_address, 10, 170),
        word(STATUTORY, 10, 700)
      ]
      [ Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words) ]
    end

    private

    def word(text, x, y)
      Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: text.length * 8, height: 20)
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

  def upload_json(text)
    Rack::Test::UploadedFile.new(StringIO.new(text), "application/json", original_filename: "manifest.json")
  end

  def upload_image(name)
    Rack::Test::UploadedFile.new(StringIO.new("#{name.split('.').first}-bytes"), "image/png", original_filename: name)
  end

  def upload_application_pdf(filename)
    Rack::Test::UploadedFile.new(
      Rails.root.join("downloads/ttb_cola_approved_applications_2026-06-13", filename),
      "application/pdf"
    )
  end

  def create_clean_batch
    with_stub_ocr do
      with_stub_verifier_v2 do
        perform_enqueued_jobs do
          post batches_path, params: {
            batch: { name: "June shipment", csv_file: upload_csv(CSV_TEXT),
                     images: [ upload_image("alpha.png"), upload_image("beta.png") ] }
          }
        end
      end
    end
    Batch.last
  end

  def with_stub_ocr
    original_engine = VerifyLabelJob.ocr_engine_factory
    original_key = VerifyLabelJob.ocr_engine_key_factory
    original_cache_enabled = Extraction::OcrCache.enabled?
    original_ready = Extraction::RuntimeDependencies.method(:check_ocr_ready)
    VerifyLabelJob.ocr_engine_factory = -> { StubOcrEngine.new }
    VerifyLabelJob.ocr_engine_key_factory = -> { "batches-controller-test-ocr" }
    Extraction::OcrCache.enabled = false
    Extraction::RuntimeDependencies.define_singleton_method(:check_ocr_ready) do
      Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 1, error_message: nil)
    end
    yield
  ensure
    VerifyLabelJob.ocr_engine_factory = original_engine
    VerifyLabelJob.ocr_engine_key_factory = original_key
    Extraction::OcrCache.enabled = original_cache_enabled
    Extraction::RuntimeDependencies.define_singleton_method(:check_ocr_ready) { original_ready.call }
  end

  def with_stub_extractor
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = ->(_provider, _model) { StubExtractor.new }
    yield
  ensure
    VerifyLabelJob.extractor_factory = original
  end

  def with_stub_verifier_v2
    original = VerifierV2.method(:verify)
    VerifierV2.define_singleton_method(:verify) do |label_application:, attempt:, mode:, provider:, model:|
      attempt.start_processing! if attempt.queued?
      verification = label_application.verifications.create!(
        overall_verdict: "pass",
        field_checks: [],
        extraction: { "pipeline" => VerifierV2::MODEL_ID, "refinement_provider" => provider, "refinement_model" => model },
        extraction_reused: false,
        model_id: VerifierV2::MODEL_ID,
        latency_ms: 40
      )
      attempt.finish_with!(verification: verification, stage_timings: { "v2" => 1 })
      verification
    end
    yield
  ensure
    VerifierV2.define_singleton_method(:verify, original)
  end

  def with_ocr_readiness(readiness)
    original_ready = Extraction::RuntimeDependencies.method(:check_ocr_ready)
    Extraction::RuntimeDependencies.define_singleton_method(:check_ocr_ready) { readiness }
    yield
  ensure
    Extraction::RuntimeDependencies.define_singleton_method(:check_ocr_ready) { original_ready.call }
  end

  test "a clean batch creates applications, runs them, and shows results" do
    batch = create_clean_batch

    assert_predicate batch, :batch_upload?
    assert_equal 2, batch.label_applications.count
    assert batch.label_applications.all?(&:batch_upload?)
    assert_equal 2, batch.done_count

    get batch_path(batch)
    assert_response :success
    assert_match(/2 of 2 checked/, response.body)
    assert_match(/ALPHA ALE/, response.body)
  end

  test "batch page uses full-width live Hotwire updates" do
    batch = create_clean_batch

    get batch_path(batch)

    assert_response :success
    assert_select "main.w-full.max-w-none"
    assert_select "turbo-cable-stream-source"
    assert_select "meta[name='turbo-refresh-method'][content='morph']"
    assert_select "meta[name='turbo-refresh-scroll'][content='preserve']"
    assert_select "[data-controller='batch-live'][data-batch-live-active-value='false']"
    assert_select "meta[name='turbo-cache-control']", count: 0
  end

  test "processing batch page avoids stale restoration cache" do
    batch = Batch.create!(
      name: "Live batch",
      source_kind: "batch_upload",
      status: "processing",
      total_rows: 1,
      processing_started_at: Time.current
    )
    application = batch.label_applications.create!(
      row_number: 1,
      serial_number: "LIVE-1",
      beverage_type: "malt",
      imported: false,
      brand_name: "LIVE ALE",
      applicant_name_address: "Live Brewing, Portland, OR",
      alcohol_content: 5.0,
      net_contents: "12 fl oz",
      source_kind: "batch_upload",
      channel: "pre_review"
    )
    application.verification_attempts.create!(
      state: "processing",
      processing_started_at: Time.current
    )

    get batch_path(batch)

    assert_response :success
    assert_select "[data-controller='batch-live'][data-batch-live-active-value='true']"
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
  end

  test "new batch page shows OCR readiness" do
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: false, latency_ms: 5, error_message: "OCR unavailable")

    with_ocr_readiness(readiness) do
      get new_batch_path
    end

    assert_response :success
    assert_match(/OCR unavailable/, response.body)
    assert_match(/Refinement model/, response.body)
    assert_no_match(/Standard validation/, response.body)
    assert_no_match(/OCR only/, response.body)
    assert_no_match(/direct comparison/, response.body)
    assert_select "select[name=demo_model] option[value='openai:gpt-5.4-nano']"
    assert_select "select[name=demo_model] option[value='anthropic:claude-haiku-4-5']"
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

  test "cola sample batch accepts manifest and attaches back artwork" do
    serial = "26083001000106"
    csv_text = <<~CSV
      filename,brand_name,class_type,alcohol_content,net_contents,bottler_address,country_of_origin,fanciful_name
      #{serial},RANSOM RIDGE,ROSE WINE,,,"MARTIN&#x27;S HONEY FARM",Product of France,SPRING RELEASE
    CSV
    manifest = JSON.generate([
      { "ttbId" => serial, "images" => [ "#{serial}-1.png", "#{serial}-2.png" ] }
    ])
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 1, error_message: nil)

    with_ocr_readiness(readiness) do
      assert_enqueued_jobs 1, only: VerifyLabelJob do
        post batches_path, params: {
          batch: {
            name: "cola samples",
            csv_file: upload_csv(csv_text),
            manifest_file: upload_json(manifest),
            images: [ upload_image("#{serial}-1.png"), upload_image("#{serial}-2.png") ]
          }
        }
      end
    end

    assert_redirected_to batch_path(Batch.last)
    application = Batch.last.label_applications.first
    attempt = application.verification_attempts.last
    job = enqueued_jobs.find { |candidate| candidate[:job] == VerifyLabelJob }

    assert_not_nil attempt
    assert_predicate attempt, :queued?
    assert_equal [ application.id, "openai", "gpt-5.4-mini", "ocr_then_vlm", attempt.id ], job[:args]
    assert_equal "RANSOM RIDGE", application.brand_name
    assert_equal "France", application.country_of_origin
    assert_equal ColaSampleIngest::NET_CONTENTS_SENTINEL, application.net_contents
    assert_equal "#{serial}-1.png", application.artwork.filename.to_s
    assert_equal "#{serial}-2.png", application.back_artwork.filename.to_s
  end

  test "application PDF batch creates applications from PDFs without a CSV" do
    manifest = Rails.root.join("downloads/ttb_cola_approved_applications_2026-06-13/manifest.json").read
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 1, error_message: nil)

    with_ocr_readiness(readiness) do
      assert_enqueued_jobs 1, only: VerifyLabelJob do
        post batches_path, params: {
          batch: {
            name: "application pdfs",
            manifest_file: upload_json(manifest),
            application_pdfs: [ upload_application_pdf("26098001000597__HUGO_S_COCKTAILS.pdf") ]
          }
        }
      end
    end

    assert_redirected_to batch_path(Batch.last)
    batch = Batch.last
    application = batch.label_applications.first
    attempt = application.verification_attempts.last
    job = enqueued_jobs.find { |candidate| candidate[:job] == VerifyLabelJob }

    assert_predicate batch, :application_pdf_upload?
    assert_equal 1, batch.total_rows
    assert_predicate application, :application_pdf_upload?
    assert_predicate application, :pre_review?
    assert_equal "260371", application.serial_number
    assert_equal "HUGO'S COCKTAILS", application.brand_name
    assert_equal "MEYER LEMON DROP MARTINI", application.fanciful_name
    assert_equal "VODKA MARTINI (UNDER 48 PROOF)", application.declared_class_type
    assert_equal ColaSampleIngest::NET_CONTENTS_SENTINEL, application.net_contents
    assert_predicate application.application_pdf, :attached?
    assert_predicate application.artwork, :attached?
    assert_not_predicate application.back_artwork, :attached?
    assert_equal "26098001000597__HUGO_S_COCKTAILS.pdf", application.application_pdf.filename.to_s
    assert_equal "26098001000597__HUGO_S_COCKTAILS-label-1.png", application.artwork.filename.to_s
    assert_not_nil attempt
    assert_predicate attempt, :queued?
    assert_equal [ application.id, "openai", "gpt-5.4-mini", "ocr_then_vlm", attempt.id ], job[:args]
  end

  test "batch upload can run an OpenAI refinement model from the shared model selector" do
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 1, error_message: nil)

    with_ocr_readiness(readiness) do
      assert_enqueued_jobs 2, only: VerifyLabelJob do
        post batches_path, params: {
          demo_model: "openai:gpt-5.4-mini",
          batch: { name: "June shipment", csv_file: upload_csv(CSV_TEXT),
                   images: [ upload_image("alpha.png"), upload_image("beta.png") ] }
        }
      end
    end

    first_application = Batch.last.label_applications.order(:row_number).first
    first_attempt = first_application.verification_attempts.last
    first_job = enqueued_jobs.find { |candidate| candidate[:job] == VerifyLabelJob && candidate[:args].first == first_application.id }

    assert_equal [ first_application.id, "openai", "gpt-5.4-mini", "ocr_then_vlm", first_attempt.id ], first_job[:args]
  end

  test "batch upload can run a Claude refinement model from the shared model selector" do
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 1, error_message: nil)

    with_ocr_readiness(readiness) do
      assert_enqueued_jobs 2, only: VerifyLabelJob do
        post batches_path, params: {
          demo_model: "anthropic:claude-haiku-4-5",
          batch: { name: "June shipment", csv_file: upload_csv(CSV_TEXT),
                   images: [ upload_image("alpha.png"), upload_image("beta.png") ] }
        }
      end
    end

    first_application = Batch.last.label_applications.order(:row_number).first
    first_attempt = first_application.verification_attempts.last
    first_job = enqueued_jobs.find { |candidate| candidate[:job] == VerifyLabelJob && candidate[:args].first == first_application.id }

    assert_equal [ first_application.id, "anthropic", "claude-haiku-4-5", "ocr_then_vlm", first_attempt.id ], first_job[:args]
  end

  test "missing files are a clear error" do
    post batches_path, params: { batch: { name: "Empty" } }
    assert_response :unprocessable_entity
    assert_match(/CSV file is required/, response.body)
  end

  test "ocr readiness failure blocks batch creation before persistence" do
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(
      ready: false,
      latency_ms: 4,
      error_message: "OCR backend unavailable"
    )

    with_ocr_readiness(readiness) do
      assert_no_enqueued_jobs do
        assert_no_difference -> { Batch.count } do
          post batches_path, params: {
            batch: { csv_file: upload_csv(CSV_TEXT),
                     images: [ upload_image("alpha.png"), upload_image("beta.png") ] }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_match(/OCR backend unavailable/, response.body)
  end

  test "verdict filter narrows the rows" do
    batch = create_clean_batch
    batch.label_applications.first.verifications.create!(overall_verdict: "pass", field_checks: [])
    batch.label_applications.second.verifications.create!(overall_verdict: "fail", field_checks: [])

    get batch_path(batch, verdict: "fail")
    assert_response :success
    assert_no_match(/ALPHA ALE/, response.body)
    assert_match(/BETA BOURBON/, response.body)
  end

  test "retry_failed re-enqueues only error rows" do
    batch = create_clean_batch
    failed_application = batch.label_applications.first
    VerifyLabelJob.new.send(:record_error, failed_application, Extraction::ExtractionError.new("boom"))

    assert_enqueued_jobs 1, only: VerifyLabelJob do
      post batch_retry_path(batch)
    end
  end

  test "retry_failed does not enqueue when ocr backend is unavailable" do
    batch = create_clean_batch
    failed_application = batch.label_applications.first
    VerifyLabelJob.new.send(:record_error, failed_application, Extraction::ExtractionError.new("boom"))
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(
      ready: false,
      latency_ms: 4,
      error_message: "OCR backend unavailable"
    )

    with_ocr_readiness(readiness) do
      assert_no_enqueued_jobs do
        post batch_retry_path(batch)
      end
    end

    assert_redirected_to batch_path(batch)
    assert_match(/OCR backend unavailable/, flash[:alert])
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

    get batch_export_path(batch)
    assert_response :success
    assert_equal "text/csv", response.media_type

    lines = response.body.lines
    assert_match(/row,serial_number,brand_name/, lines.first)
    assert_match(/26-1,ALPHA ALE,malt/, response.body)
    assert_match(/approve/, response.body)
  end
end
