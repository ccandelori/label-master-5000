# frozen_string_literal: true

require "test_helper"

class ChecksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def assert_latest_verification_job(application, provider, model, mode)
    attempt = application.reload.verification_attempts.last
    job = enqueued_jobs.reverse.find { |candidate| candidate[:job] == VerifyLabelJob && candidate[:args].first == application.id }

    assert_not_nil attempt
    assert_predicate attempt, :queued?
    assert_not_nil job
    assert_equal [ application.id, provider, model, mode, attempt.id ], job[:args]
  end

  def create_application(channel)
    LabelApplication.create!(
      channel: channel,
      serial_number: "26-#{channel.upcase}",
      beverage_type: "malt",
      brand_name: "PENDING PILSNER",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
  end

  test "run validation enqueues a verification job and returns to history" do
    application = create_application("submitted")

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             headers: { "HTTP_REFERER" => validation_history_path(tab: "unchecked") }
      end
    end
    assert_latest_verification_job(application, nil, nil, nil)
    assert_redirected_to validation_history_path(tab: "unchecked")
  end

  test "validation reruns honor the configured refinement default" do
    application = create_application("pre_review")

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             params: { demo_model: "quality" }
      end
    end
    assert_latest_verification_job(application, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "validation reruns can explicitly choose a Claude refinement model" do
    application = create_application("pre_review")

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             params: { demo_model: "anthropic:claude-haiku-4-5" }
      end
    end
    assert_latest_verification_job(application, "anthropic", "claude-haiku-4-5", "ocr_then_vlm")
  end

  test "validation reruns with a stale OCR-only value fall back to configured refinement" do
    application = create_application("pre_review")

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             params: { demo_model: "ocr_only" }
      end
    end
    assert_latest_verification_job(application, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "the demo model choice never steers submitted-channel work" do
    application = create_application("submitted")

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             params: { demo_model: "anthropic:claude-haiku-4-5" }
      end
    end
    assert_latest_verification_job(application, nil, nil, nil)
  end

  test "a choice outside the configured menu runs the default" do
    application = create_application("pre_review")

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             params: { demo_model: "openai:made-up-model" }
      end
    end
    assert_latest_verification_job(application, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "missing comparison model configuration falls back to configured refinement" do
    application = create_application("pre_review")
    original = Rails.application.config.x.extraction.demo_models
    Rails.application.config.x.extraction.demo_models = nil

    assert_difference -> { application.verification_attempts.reload.count } do
      assert_enqueued_with(job: VerifyLabelJob) do
        post label_application_check_path(application),
             params: { demo_model: "anthropic:claude-haiku-4-5" }
      end
    end
    assert_latest_verification_job(application, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  ensure
    Rails.application.config.x.extraction.demo_models = original
  end
end
