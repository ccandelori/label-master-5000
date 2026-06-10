# frozen_string_literal: true

require "test_helper"

class DecisionsControllerTest < ActionDispatch::IntegrationTest
  def create_verified_application(channel:)
    application = LabelApplication.create!(
      channel: channel,
      serial_number: "26-88",
      beverage_type: "malt",
      brand_name: "JUDGED JUICE",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
    verification = application.verifications.create!(overall_verdict: "pass", field_checks: [])
    [ application, verification ]
  end

  test "decisions are recorded on submitted applications" do
    application, verification = create_verified_application(channel: "submitted")

    post label_application_decision_path(application),
         params: { decision: { verification_id: verification.id, decision: "approve", note: "" } }

    assert_redirected_to label_application_path(application)
    assert_equal "approve", verification.reload.decision
  end

  test "decisions are rejected for pre-review applications" do
    application, verification = create_verified_application(channel: "pre_review")

    post label_application_decision_path(application),
         params: { decision: { verification_id: verification.id, decision: "approve", note: "" } }

    assert_redirected_to label_application_path(application)
    assert_match(/still in pre-review/, flash[:alert])
    assert_nil verification.reload.decision
  end
end
