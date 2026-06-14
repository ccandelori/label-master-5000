# frozen_string_literal: true

require "test_helper"

class DecisionsControllerTest < ActionDispatch::IntegrationTest
  def create_verified_application(channel:, serial: "26-88", source_kind: "manual")
    application = LabelApplication.create!(
      channel: channel,
      source_kind: source_kind,
      serial_number: serial,
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
    assert_match(/production-review applications only/, flash[:alert])
    assert_nil verification.reload.decision
  end

  test "decisions are rejected for hidden or quarantined submissions" do
    eval_record, eval_verification = create_verified_application(
      channel: "submitted", serial: "26-EVAL", source_kind: "registry_eval"
    )
    quarantined, quarantined_verification = create_verified_application(
      channel: "submitted", serial: "26-QUAR", source_kind: "manual"
    )
    quarantined.quarantine!(reasons: [ "identical_front_back_artwork" ])

    post label_application_decision_path(eval_record),
         params: { decision: { verification_id: eval_verification.id, decision: "approve", note: "" } }
    assert_match(/production-review applications only/, flash[:alert])
    assert_nil eval_verification.reload.decision

    post label_application_decision_path(quarantined),
         params: { decision: { verification_id: quarantined_verification.id, decision: "approve", note: "" } }
    assert_match(/production-review applications only/, flash[:alert])
    assert_nil quarantined_verification.reload.decision
  end
end
