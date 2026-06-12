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

  test "creating an application enqueues verification and redirects" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({})
    end
    application = LabelApplication.last
    assert_redirected_to label_application_path(application)
    assert_equal "26-1042", application.serial_number
    assert application.pre_review?, "form-created applications start in the pre-review sandbox"
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
    assert_match(/Checking this label now/, response.body)
  end

  test "show captions an approximate location instead of cropping it" do
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
    assert_match(/Location approximate — not OCR-verified/, response.body)
    assert_no_match(/field_crop/, response.body)
  end

  test "varietals round-trip through the comma-separated form field" do
    post label_applications_path, params: valid_params(beverage_type: "wine", varietals_list: "Merlot, Syrah")
    assert_equal %w[Merlot Syrah], LabelApplication.last.varietals
  end

  test "creating with a demo model choice enqueues the override" do
    assert_enqueued_with(job: VerifyLabelJob) do
      post label_applications_path, params: valid_params({}).merge(demo_model: "anthropic:claude-haiku-4-5")
    end
    job_args = enqueued_jobs.last[:args]
    assert_equal [ LabelApplication.last.id, "anthropic", "claude-haiku-4-5" ], job_args
  end

  test "the new form carries the demo model menu" do
    get new_label_application_path
    assert_response :success
    assert_match(/Demo settings/, response.body)
    assert_select "select[name=demo_model] option", minimum: 2
  end

  test "the pre-review record page offers a model re-check; submitted does not" do
    post label_applications_path, params: valid_params({})
    application = LabelApplication.last

    get label_application_path(application)
    assert_select "select[name=demo_model]"
    assert_match(/Re-check/, response.body)

    application.update!(channel: "submitted")
    get label_application_path(application)
    assert_select "select[name=demo_model]", count: 0
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
end
