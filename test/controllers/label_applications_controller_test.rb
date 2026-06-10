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

  test "varietals round-trip through the comma-separated form field" do
    post label_applications_path, params: valid_params(beverage_type: "wine", varietals_list: "Merlot, Syrah")
    assert_equal %w[Merlot Syrah], LabelApplication.last.varietals
  end
end
