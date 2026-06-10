# frozen_string_literal: true

require "test_helper"

class ChecksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "run check enqueues a verification job and returns to the queue" do
    application = LabelApplication.create!(
      channel: "submitted",
      serial_number: "26-UNCHECKED",
      beverage_type: "malt",
      brand_name: "PENDING PILSNER",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )

    assert_enqueued_with(job: VerifyLabelJob, args: [ application.id ]) do
      post label_application_check_path(application),
           headers: { "HTTP_REFERER" => reviewer_queue_path(tab: "unchecked") }
    end
    assert_redirected_to reviewer_queue_path(tab: "unchecked")
  end
end
