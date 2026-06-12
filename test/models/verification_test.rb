# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

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

  test "a reject decision generates the rejection notice; approve does not" do
    verification = Verification.create!(
      label_application: application,
      overall_verdict: "fail",
      field_checks: [ sample_check(verdict: "fail") ]
    )

    verification.record_decision(decision: "reject", note: nil)
    assert_match(/DRAFT REJECTION NOTICE/, verification.rejection_notice)
    assert_match(/Government warning/, verification.rejection_notice)

    verification.undo_decision
    assert_nil verification.rejection_notice

    verification.record_decision(decision: "approve", note: nil)
    assert_nil verification.rejection_notice
  end
end

# Queue liveness: verification events and filings refresh every open
# reviewer queue. Refresh broadcasts are debounced onto a scheduled task,
# so each action waits on the debouncer before asserting.
class VerificationQueueBroadcastTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  def application
    @application ||= LabelApplication.create!(
      serial_number: "26-2042",
      channel: "submitted",
      beverage_type: "spirits",
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      net_contents: "750 mL"
    )
  end

  def drain_refresh_debounce
    Turbo::StreamsChannel.refresh_debouncer_for(:reviewer_queue).wait
  end

  test "a new verification refreshes the reviewer queue" do
    app = nil
    perform_enqueued_jobs { app = application; drain_refresh_debounce }

    assert_turbo_stream_broadcasts :reviewer_queue, count: 1 do
      perform_enqueued_jobs do
        app.verifications.create!(overall_verdict: "pass", field_checks: [])
        drain_refresh_debounce
      end
    end
  end

  test "recording a decision refreshes the reviewer queue" do
    verification = nil
    perform_enqueued_jobs do
      verification = application.verifications.create!(overall_verdict: "fail", field_checks: [])
      drain_refresh_debounce
    end

    assert_turbo_stream_broadcasts :reviewer_queue, count: 1 do
      perform_enqueued_jobs do
        verification.record_decision(decision: "reject", note: nil)
        drain_refresh_debounce
      end
    end
  end

  test "filing an application refreshes the reviewer queue" do
    assert_turbo_stream_broadcasts :reviewer_queue, count: 1 do
      perform_enqueued_jobs do
        application
        drain_refresh_debounce
      end
    end
  end
end
