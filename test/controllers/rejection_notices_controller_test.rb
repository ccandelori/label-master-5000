# frozen_string_literal: true

require "test_helper"

class RejectionNoticesControllerTest < ActionDispatch::IntegrationTest
  def create_verified_application
    application = LabelApplication.create!(
      channel: "submitted",
      serial_number: "26-90",
      beverage_type: "malt",
      brand_name: "NOTICED ALE",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
    verification = application.verifications.create!(
      overall_verdict: "fail",
      field_checks: [ { field: "government_warning_prefix", verdict: "fail",
                        expected: "GOVERNMENT WARNING", extracted: "Government Warning",
                        citation: "27 CFR 16.22", note: "Must be capital letters" } ]
    )
    [ application, verification ]
  end

  test "rejecting creates a downloadable notice" do
    application, verification = create_verified_application

    post label_application_decision_path(application),
         params: { decision: { verification_id: verification.id, decision: "reject", note: "" } }

    get label_application_rejection_notice_path(application, download: 1)
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_match(/DRAFT REJECTION NOTICE/, response.body)
    assert_match(/27 CFR 16\.22/, response.body)
  end

  test "approving leaves no notice to fetch" do
    application, verification = create_verified_application

    post label_application_decision_path(application),
         params: { decision: { verification_id: verification.id, decision: "approve", note: "" } }

    get label_application_rejection_notice_path(application)
    assert_redirected_to label_application_path(application)
    assert_match(/no rejection notice/, flash[:alert])
  end
end
