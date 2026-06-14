# frozen_string_literal: true

require "application_system_test_case"

class ValidationHistoryFlowTest < ApplicationSystemTestCase
  def create_application(serial:, brand:)
    LabelApplication.create!(
      channel: "submitted",
      serial_number: serial,
      brand_name: brand,
      beverage_type: "malt",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
  end

  def add_verification(application, verdict:, field_checks: [])
    application.verifications.create!(
      overall_verdict: verdict,
      field_checks: field_checks,
      extraction: { "fields" => {} }
    )
  end

  test "user approves a clean pass and rejects a failure through history" do
    clean = create_application(serial: "26-CLEAN", brand: "CLEAN LAGER")
    add_verification(clean, verdict: "pass")
    failing = create_application(serial: "26-DIRTY", brand: "DIRTY STOUT")
    add_verification(failing, verdict: "fail", field_checks: [
      { field: "government_warning_prefix", verdict: "fail", expected: "GOVERNMENT WARNING",
        extracted: "Government Warning", citation: "27 CFR 16.22",
        note: "GOVERNMENT WARNING must appear in capital letters" }
    ])

    # Rule failures stay in the needs-attention history list.
    visit validation_history_path(tab: "needs_attention")
    assert_text "DIRTY STOUT"
    assert_text "Details"
    assert_no_text "CLEAN LAGER"

    # One-click approve from the passed tab.
    click_on "Passed"
    assert_text "CLEAN LAGER"
    click_on "Approve"
    assert_text "Decision recorded"
    assert clean.latest_verification.reload.decided_to_approve?

    # Reject the failure from its record page; the breadcrumb leads back.
    click_on "Needs attention"
    click_on "Details"
    assert_text "GOVERNMENT WARNING must appear in capital letters"
    within("nav[aria-label='Breadcrumb']") { assert_link "History" }
    click_on "Reject"
    assert_text "Decision recorded"

    # Both now sit under decided; the working tabs are clear.
    visit validation_history_path(tab: "decided")
    assert_text "CLEAN LAGER"
    assert_text "DIRTY STOUT"
  end
end
