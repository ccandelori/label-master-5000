# frozen_string_literal: true

require "test_helper"

class SampleValidationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def assert_latest_verification_job(application, provider, model, mode)
    attempt = application.reload.verification_attempts.last
    job = enqueued_jobs.reverse.find { |candidate| candidate[:job] == VerifyLabelJob && candidate[:args].first == application.id }

    assert_not_nil attempt
    assert_predicate attempt, :queued?
    assert_not_nil job
    assert_equal [ application.id, provider, model, mode, attempt.id ], job[:args]
  end

  def create_sample
    LabelApplication.create!(
      channel: "pre_review",
      source_kind: "seed_application_pdf",
      serial_number: "26-SAMPLE",
      beverage_type: "spirits",
      brand_name: "SAMPLE BRAND",
      fanciful_name: "SAMPLE FANCIFUL",
      applicant_name_address: "Sample Distilling, Louisville, KY",
      alcohol_content: 40.0,
      net_contents: "750 mL"
    ).tap do |application|
      application.artwork.attach(
        io: StringIO.new(File.binread(Rails.root.join("test/fixtures/files/label.png"))),
        filename: "label.png",
        content_type: "image/png"
      )
    end
  end

  test "creating from a sample starts a fresh validation run" do
    sample = create_sample

    assert_difference -> { LabelApplication.count }, 1 do
      assert_enqueued_with(job: VerifyLabelJob) do
        post sample_validation_path, params: { sample_id: sample.id }
      end
    end

    validation = LabelApplication.where.not(id: sample.id).order(:id).last
    assert_redirected_to label_application_path(validation)
    assert_equal "Sample validation started.", flash[:notice]
    assert_not_equal sample.id, validation.id
    assert_predicate validation, :pre_review?
    assert_equal "manual", validation.source_kind
    assert_equal "26-SAMPLE", validation.serial_number
    assert_equal "SAMPLE BRAND", validation.brand_name
    assert_equal "SAMPLE FANCIFUL", validation.fanciful_name
    assert_equal sample.artwork.blob, validation.artwork.blob
    assert_equal "seed_application_pdf", sample.reload.source_kind
    assert_latest_verification_job(validation, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "creating from a sample can run a Claude refinement model" do
    sample = create_sample

    assert_difference -> { LabelApplication.count }, 1 do
      assert_enqueued_with(job: VerifyLabelJob) do
        post sample_validation_path, params: { sample_id: sample.id, demo_model: "anthropic:claude-haiku-4-5" }
      end
    end

    validation = LabelApplication.where.not(id: sample.id).order(:id).last
    assert_redirected_to label_application_path(validation)
    assert_latest_verification_job(validation, "anthropic", "claude-haiku-4-5", "ocr_then_vlm")
  end

  test "creating from a sample with a stale OCR-only value falls back to configured refinement" do
    sample = create_sample

    assert_difference -> { LabelApplication.count }, 1 do
      assert_enqueued_with(job: VerifyLabelJob) do
        post sample_validation_path, params: { sample_id: sample.id, demo_model: "ocr_only" }
      end
    end

    validation = LabelApplication.where.not(id: sample.id).order(:id).last
    assert_redirected_to label_application_path(validation)
    assert_latest_verification_job(validation, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "non-sample records cannot be started through the sample route" do
    application = LabelApplication.create!(
      channel: "pre_review",
      source_kind: "manual",
      serial_number: "26-MANUAL",
      beverage_type: "malt",
      brand_name: "MANUAL BRAND",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )

    assert_no_enqueued_jobs do
      post sample_validation_path, params: { sample_id: application.id }
    end
    assert_response :not_found
  end
end
