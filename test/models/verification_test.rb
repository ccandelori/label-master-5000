# frozen_string_literal: true

require "test_helper"

class VerificationTest < ActiveSupport::TestCase
  def application
    @application ||= LabelApplication.create!(
      serial_number: "26-1042",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      net_contents: "750 mL"
    )
  end

  def sample_check(verdict:)
    FieldCheck.new(
      field: "government_warning",
      verdict: verdict,
      expected: "GOVERNMENT WARNING: ...",
      extracted: "Government Warning: ...",
      citation: "BAM Vol 2, 1-17",
      note: "Prefix must be in capital letters"
    )
  end

  test "field checks round-trip through jsonb as FieldCheck objects" do
    verification = Verification.create!(
      label_application: application,
      overall_verdict: "fail",
      field_checks: [ sample_check(verdict: "fail") ]
    )

    reloaded = Verification.find(verification.id).field_checks
    assert_equal 1, reloaded.size
    assert_instance_of FieldCheck, reloaded.first
    assert_equal sample_check(verdict: "fail"), reloaded.first
  end

  test "rejects unknown overall verdict" do
    verification = Verification.new(label_application: application, overall_verdict: "sideways")
    assert_not verification.valid?
  end

  test "decision is optional until recorded" do
    verification = Verification.create!(label_application: application, overall_verdict: "pass")
    assert_nil verification.decision

    verification.record_decision(decision: "approve", note: "Looks right")
    assert_predicate verification, :decided_to_approve?
    assert_not_nil verification.decided_at
  end

  test "destroying an application destroys its verification history" do
    Verification.create!(label_application: application, overall_verdict: "pass")
    assert_difference("Verification.count", -1) { application.destroy }
  end
end
