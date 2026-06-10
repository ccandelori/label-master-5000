# frozen_string_literal: true

require "test_helper"

class SubmissionsControllerTest < ActionDispatch::IntegrationTest
  def create_application(channel:)
    LabelApplication.create!(
      channel: channel,
      serial_number: "26-77",
      beverage_type: "malt",
      brand_name: "PROMOTED PILS",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
  end

  test "submitting a pre-review application flips it into the reviewer queue" do
    application = create_application(channel: "pre_review")

    post label_application_submission_path(application)
    assert_redirected_to label_application_path(application)
    assert application.reload.submitted?

    # Not yet verified, so it surfaces under the unchecked tab.
    get reviewer_queue_path(tab: "unchecked")
    assert_match(/PROMOTED PILS/, response.body)
  end

  test "an already-submitted application cannot be submitted again" do
    application = create_application(channel: "submitted")

    post label_application_submission_path(application)
    assert_redirected_to label_application_path(application)
    assert_match(/already been submitted/, flash[:alert])
  end
end
