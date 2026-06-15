# frozen_string_literal: true

require "test_helper"

class LabelApplicationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def valid_params(overrides)
    {
      label_application: {
        serial_number: "26-1042",
        beverage_type: "spirits",
        brand_name: "OLD TOM DISTILLERY",
        applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
        alcohol_content: "45",
        net_contents: "750 mL",
        artwork: fixture_file_upload("label.png", "image/png")
      }.merge(overrides)
    }
  end

  def assert_latest_verification_job(application, provider, model, mode)
    attempt = application.reload.verification_attempts.last
    job = enqueued_jobs.reverse.find { |candidate| candidate[:job] == VerifyLabelJob && candidate[:args].first == application.id }

    assert_not_nil attempt
    assert_predicate attempt, :queued?
    assert_not_nil job
    assert_equal [ application.id, provider, model, mode, attempt.id ], job[:args]
  end

  test "creating an application enqueues verification and redirects" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({})
    end
    application = LabelApplication.last
    assert_redirected_to label_application_path(application)
    assert_equal "26-1042", application.serial_number
    assert application.pre_review?, "form-created applications start in the validation workspace"
  end

  test "missing required fields re-render the form" do
    assert_no_enqueued_jobs do
      post label_applications_path, params: valid_params(brand_name: "")
    end
    assert_response :unprocessable_entity
    assert_match(/Brand name/, response.body)
  end

  test "disallowed artwork content types are rejected" do
    params = valid_params(artwork: fixture_file_upload("label.txt", "text/plain"))
    assert_no_enqueued_jobs do
      post label_applications_path, params: params
    end
    assert_response :unprocessable_entity
    assert_match(/JPEG, PNG, WebP, or PDF/, response.body)
  end

  test "updating fields re-enqueues verification" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last

    assert_enqueued_with(job: VerifyLabelJob) do
      patch label_application_path(application), params: { label_application: { alcohol_content: "40" } }
    end
    assert_redirected_to label_application_path(application)
    assert_equal 40.0, application.reload.alcohol_content.to_f
  end

  test "show renders the processing state before any verification exists" do
    post label_applications_path, params: valid_params({})
    get label_application_path(LabelApplication.last)
    assert_response :success
    assert_select "#verification_panel"
    assert_match(/Running validation/, response.body)
  end

  test "show renders running state while a revalidation is queued" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    application.verifications.create!(overall_verdict: "pass", field_checks: [], model_id: "quality-v1", latency_ms: 1200)
    application.verify_later(provider: nil, model: nil, mode: nil)

    get label_application_path(application)

    assert_response :success
    assert_select "#verification_panel"
    assert_match(/Running validation/, response.body)
    assert_match(/Earlier checks/, response.body)
    assert_match(/Passed/, response.body)
  end

  test "show omits model-only locations instead of cropping them" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    application.verifications.create!(
      overall_verdict: "needs_review",
      field_checks: [
        { field: "brand_name", verdict: "needs_review", expected: "OLD TOM DISTILLERY",
          extracted: "OLD TOM", citation: "BAM Vol 2 1-1", note: "Differs from the application" }
      ],
      extraction: {
        "image_width" => 800, "image_height" => 1000,
        "fields" => { "brand_name" => { "text" => "OLD TOM", "bbox" => [ 10, 10, 100, 20 ],
                                        "bbox_source" => "model", "page" => 1 } }
      }
    )

    get label_application_path(application)
    assert_response :success
    assert_no_match(/Location approximate — not OCR-verified/, response.body)
    assert_no_match(/field_crop/, response.body)
  end

  test "show renders one crop request for checks sharing the same OCR field" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    verification = application.verifications.create!(
      overall_verdict: "fail",
      field_checks: [
        { field: "government_warning_text", verdict: "fail", expected: "GOVERNMENT WARNING: ...",
          extracted: "GOVERNMENT WARNING: ...", citation: "27 CFR 16.21", note: "Required warning" },
        { field: "government_warning_prefix", verdict: "fail", expected: "GOVERNMENT WARNING",
          extracted: "GOVERNMENT WARNING", citation: "27 CFR 16.22", note: "Prefix issue" },
        { field: "government_warning_bold", verdict: "pass", expected: "Bold heading",
          extracted: "Bold heading", citation: "27 CFR 16.22", note: nil },
        { field: "government_warning_paragraph", verdict: "pass", expected: "Separate paragraph",
          extracted: "Separate paragraph", citation: "27 CFR 16.22", note: nil }
      ],
      extraction: {
        "fields" => {
          "government_warning" => { "text" => "GOVERNMENT WARNING: ...", "bbox" => [ 10, 10, 250, 40 ],
                                    "bbox_source" => "ocr", "bbox_basis" => [ 800, 1000 ], "page" => 1 }
        }
      }
    )
    application.latest_verification_attempt.finish_with!(verification: verification, stage_timings: {})

    get label_application_path(application)

    assert_response :success
    crop_path = label_application_field_crop_path(application, field: "government_warning")
    assert_equal 1, response.body.scan(crop_path).size
  end

  test "varietals round-trip through the comma-separated form field" do
    post label_applications_path, params: valid_params(beverage_type: "wine", varietals_list: "Merlot, Syrah")
    assert_equal %w[Merlot Syrah], LabelApplication.last.varietals
  end

  test "creating with the legacy standard validation choice runs the configured refinement model" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({}).merge(demo_model: "quality")
    end
    assert_latest_verification_job(LabelApplication.last, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "creating with a Claude refinement model enqueues OCR then VLM refinement" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({}).merge(demo_model: "anthropic:claude-haiku-4-5")
    end
    assert_latest_verification_job(LabelApplication.last, "anthropic", "claude-haiku-4-5", "ocr_then_vlm")
  end

  test "creating with gpt nano refinement model enqueues OCR then VLM refinement" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({}).merge(demo_model: "openai:gpt-5.4-nano")
    end
    assert_latest_verification_job(LabelApplication.last, "openai", "gpt-5.4-nano", "ocr_then_vlm")
  end

  test "creating with a stale OCR-only menu value falls back to configured refinement" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({}).merge(demo_model: "ocr_only")
    end
    assert_latest_verification_job(LabelApplication.last, "openai", "gpt-5.4-mini", "ocr_then_vlm")
  end

  test "the new form carries the validation model menu" do
    get new_label_application_path
    assert_response :success
    assert_match(/Refinement model/, response.body)
    assert_match(/OCR \+ GPT-5.4 nano refinement/, response.body)
    assert_match(/OCR \+ Claude Haiku 4.5 refinement/, response.body)
    assert_no_match(/Standard validation/, response.body)
    assert_no_match(/OCR only/, response.body)
    assert_no_match(/direct comparison/, response.body)
    assert_select "select[name=demo_model] option[value='openai:gpt-5.4-nano']"
    assert_select "select[name=demo_model] option[value='anthropic:claude-haiku-4-5']"
    assert_select "select[name=demo_model] option", count: 4
  end

  test "the new form keeps upload and run controls in a responsive setup rail" do
    get new_label_application_path
    assert_response :success

    assert_select "form[class*='lg:grid-cols']"
    assert_select "aside[aria-label='Validation setup']" do
      assert_select "input[type=file]", count: 2
      assert_select "select[name=demo_model]"
      assert_select "input[type=submit][value='Run validation']"
    end
  end

  test "the validation record page offers model revalidation; submitted does not" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last

    get label_application_path(application)
    assert_select "select[name=demo_model]"
    assert_match(/Revalidate/, response.body)

    application.update!(channel: "submitted")
    get label_application_path(application)
    assert_select "select[name=demo_model]", count: 0
  end

  test "the validation record page selects the refinement model used by the latest verification" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    application.verifications.create!(
      overall_verdict: "fail",
      field_checks: [],
      model_id: VerifierV2::MODEL_ID,
      extraction: {
        "vlm_refinement" => {
          "status" => "complete",
          "provider" => "anthropic",
          "model" => "claude-haiku-4-5",
          "fields" => [ "government_warning_text" ]
        }
      }
    )

    get label_application_path(application)

    assert_select "select[name=demo_model] option[value='anthropic:claude-haiku-4-5'][selected]"
    assert_select "select[name=demo_model] option[value='openai:gpt-5.4-mini'][selected]", count: 0
  end

  test "the validation record page displays OCR and selected VLM timings" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    verification = application.verifications.create!(
      overall_verdict: "fail",
      field_checks: [],
      model_id: VerifierV2::MODEL_ID,
      latency_ms: 4100,
      extraction: {
        "vlm_refinement" => {
          "status" => "complete",
          "provider" => "anthropic",
          "model" => "claude-haiku-4-5",
          "duration_ms" => 812.3,
          "fields" => [ "government_warning_text" ]
        }
      }
    )
    application.latest_verification_attempt.finish_with!(
      verification: verification,
      stage_timings: { "ocr_ms" => 2345.6 }
    )

    get label_application_path(application)

    assert_match(/verifier-v2-v1 .* checked in 4\.1s/, response.body)
    assert_match(/OCR 2\.3s/, response.body)
    assert_match(/Claude Haiku 4\.5 refinement 0\.8s/, response.body)
  end

  test "verification history names the model that produced each check" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    2.times do |i|
      application.verifications.create!(
        overall_verdict: "pass", field_checks: [], model_id: "claude-haiku-4-5",
        created_at: Time.current - i.minutes
      )
    end

    get label_application_path(application)
    assert_match(/Claude Haiku 4.5/, response.body)
  end

  test "submitted record page is the check workspace" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last
    application.update!(channel: "submitted")
    verification = application.verifications.create!(
      overall_verdict: "needs_review",
      field_checks: [
        { field: "brand_name", verdict: "needs_review", expected: "OLD TOM DISTILLERY",
          extracted: "OLD TOM", citation: "TTB F 5100.31 item 7", note: "Differs" }
      ],
      extraction: {
        "fields" => {
          "brand_name" => { "text" => "OLD TOM", "bbox" => [ 10, 10, 100, 20 ],
                            "bbox_source" => "ocr", "bbox_basis" => [ 800, 1000 ], "page" => 1 }
        }
      }
    )
    application.latest_verification_attempt.finish_with!(verification: verification, stage_timings: {})

    get label_application_path(application)

    assert_response :success
    assert_select "main#check_workspace"
    assert_match(/Label artwork/, response.body)
    assert_match(/Findings/, response.body)
    assert_no_match(/reviewer\/review\?start=#{application.id}/, response.body)
    assert_no_match(/Review queue/, response.body)
  end
end
