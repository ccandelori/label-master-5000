# frozen_string_literal: true

require "test_helper"

class ReviewerQueueControllerTest < ActionDispatch::IntegrationTest
  def create_application(channel:, serial:)
    LabelApplication.create!(
      channel: channel,
      serial_number: serial,
      beverage_type: "malt",
      brand_name: "BRAND #{serial}",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
  end

  test "the queue lists submitted applications only" do
    create_application(channel: "submitted", serial: "SUB-1")
    create_application(channel: "pre_review", serial: "PRE-1")

    get reviewer_queue_path
    assert_response :success
    assert_match(/SUB-1/, response.body)
    assert_no_match(/PRE-1/, response.body)
  end

  test "the queue is the application root" do
    get root_path
    assert_response :success
    assert_match(/Review queue/, response.body)
  end

  test "an empty queue says so" do
    create_application(channel: "pre_review", serial: "PRE-1")

    get reviewer_queue_path
    assert_match(/The queue is empty/, response.body)
  end
end
