# frozen_string_literal: true

require "test_helper"

class RejectionNoticeTest < ActiveSupport::TestCase
  def application
    @application ||= LabelApplication.create!(
      channel: "submitted",
      serial_number: "26-1042",
      beverage_type: "spirits",
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      net_contents: "750 mL"
    )
  end

  def check(field:, verdict:, note:, citation:)
    { field: field, verdict: verdict, expected: "expected value", extracted: "label value",
      note: note, citation: citation }
  end

  def verification(checks:, note: nil)
    application.verifications.create!(
      overall_verdict: "fail",
      field_checks: checks,
      decision: "reject",
      decision_note: note,
      decided_at: Time.utc(2026, 6, 10, 12, 0)
    )
  end

  test "the notice carries identifiers, findings, and citations" do
    v = verification(checks: [
      check(field: "government_warning_prefix", verdict: "fail",
            note: "GOVERNMENT WARNING must appear in capital letters", citation: "27 CFR 16.22"),
      check(field: "net_contents", verdict: "needs_review",
            note: "Statement form needs a judgment call", citation: "27 CFR 5.203"),
      check(field: "brand_name", verdict: "pass", note: nil, citation: nil)
    ])

    notice = RejectionNotice.generate(application: application, verification: v)

    assert_match(/26-1042/, notice)
    assert_match(/OLD TOM DISTILLERY/, notice)
    assert_match(/June 10, 2026/, notice)
    assert_match(/1\. Government warning prefix - Does not conform\./, notice)
    assert_match(/27 CFR 16\.22/, notice)
    assert_match(/2\. Net contents - Requires correction or clarification\./, notice)
    assert_match(/27 CFR 5\.203/, notice)
    assert_no_match(/\d+\. Brand name/, notice, "passing checks must not appear as findings")
    assert_match(/not an official TTB communication/, notice)
  end

  test "fails are listed before needs_review findings" do
    v = verification(checks: [
      check(field: "net_contents", verdict: "needs_review", note: "judgment", citation: "27 CFR 5.203"),
      check(field: "government_warning_prefix", verdict: "fail", note: "caps", citation: "27 CFR 16.22")
    ])

    notice = RejectionNotice.generate(application: application, verification: v)
    assert_operator notice.index("Government warning prefix"), :<, notice.index("Net contents")
  end

  test "a reject without findings leans on the reviewer note" do
    v = verification(checks: [ check(field: "brand_name", verdict: "pass", note: nil, citation: nil) ],
                     note: "Label art does not match the submitted artwork.")

    notice = RejectionNotice.generate(application: application, verification: v)
    assert_match(/No individual label findings were cited/, notice)
    assert_match(/REVIEWER NOTE/, notice)
    assert_match(/does not match the submitted artwork/, notice)
  end

  test "generation is deterministic" do
    v = verification(checks: [
      check(field: "government_warning_prefix", verdict: "fail", note: "caps", citation: "27 CFR 16.22")
    ])

    assert_equal RejectionNotice.generate(application: application, verification: v),
                 RejectionNotice.generate(application: application, verification: v)
  end
end
