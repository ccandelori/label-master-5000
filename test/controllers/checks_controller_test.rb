# frozen_string_literal: true

require "test_helper"

class ChecksControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

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

  test "run check enqueues a verification job and returns to the queue" do
    application = create_application("submitted")

    assert_enqueued_with(job: VerifyLabelJob, args: [ application.id, nil, nil ]) do
      post label_application_check_path(application),
           headers: { "HTTP_REFERER" => reviewer_queue_path(tab: "unchecked") }
    end
    assert_redirected_to reviewer_queue_path(tab: "unchecked")
  end

  test "a pre-review re-check honors the demo model choice" do
    application = create_application("pre_review")

    assert_enqueued_with(job: VerifyLabelJob, args: [ application.id, "anthropic", "claude-haiku-4-5" ]) do
      post label_application_check_path(application),
           params: { demo_model: "anthropic:claude-haiku-4-5" }
    end
  end

  test "the demo model choice never steers submitted-channel work" do
    application = create_application("submitted")

    assert_enqueued_with(job: VerifyLabelJob, args: [ application.id, nil, nil ]) do
      post label_application_check_path(application),
           params: { demo_model: "anthropic:claude-haiku-4-5" }
    end
  end

  test "a choice outside the configured menu runs the default" do
    application = create_application("pre_review")

    assert_enqueued_with(job: VerifyLabelJob, args: [ application.id, nil, nil ]) do
      post label_application_check_path(application),
           params: { demo_model: "openai:made-up-model" }
    end
  end
end
