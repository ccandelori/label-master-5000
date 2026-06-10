# frozen_string_literal: true

require "application_system_test_case"

class ReviewerQueueTest < ApplicationSystemTestCase
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

  test "agent approves a clean pass and rejects a failure through the queue" do
    clean = create_application(serial: "26-CLEAN", brand: "CLEAN LAGER")
    add_verification(clean, verdict: "pass")
    failing = create_application(serial: "26-DIRTY", brand: "DIRTY STOUT")
    add_verification(failing, verdict: "fail", field_checks: [
      { field: "government_warning_prefix", verdict: "fail", expected: "GOVERNMENT WARNING",
        extracted: "Government Warning", citation: "27 CFR 16.22",
        note: "GOVERNMENT WARNING must appear in capital letters" }
    ])

    # Worst work first: the failure is on the default tab.
    visit reviewer_queue_path
    assert_text "DIRTY STOUT"
    assert_no_text "CLEAN LAGER"

    # One-click approve from the ready-to-approve tab.
    click_on "Ready to approve"
    assert_text "CLEAN LAGER"
    click_on "✓ Approve"
    assert_text "Decision recorded"
    assert clean.latest_verification.reload.decided_to_approve?

    # Reject the failure from its record page.
    click_on "Needs attention"
    click_on "Open"
    assert_text "GOVERNMENT WARNING must appear in capital letters"
    click_on "✗ Reject"
    assert_text "Decision recorded"

    # Both now sit under decided; the working tabs are clear.
    visit reviewer_queue_path(tab: "decided")
    assert_text "CLEAN LAGER"
    assert_text "DIRTY STOUT"
  end

  test "review mode shell renders the worst undecided item" do
    failing = create_application(serial: "26-HUD", brand: "HUD PORTER")
    add_verification(failing, verdict: "fail")

    visit reviewer_review_path
    assert_text "Exit review mode"
    assert_match(/26-HUD/, page.html)
  end
end
