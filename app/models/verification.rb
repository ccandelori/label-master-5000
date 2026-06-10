# frozen_string_literal: true

class Verification < ApplicationRecord
  belongs_to :label_application

  enum :overall_verdict, {
    pass: "pass",
    pass_with_note: "pass_with_note",
    fail: "fail",
    needs_review: "needs_review",
    request_retake: "request_retake"
  }, validate: true

  enum :decision, {
    approve: "approve",
    reject: "reject",
    retake_requested: "retake_requested"
  }, validate: { allow_nil: true }, prefix: :decided_to

  # Typed boundary around the jsonb column: readers always get FieldCheck
  # objects, writers may pass FieldCheck objects or their hashes.
  def field_checks
    Array(super).map { |h| FieldCheck.from_h(h) }
  end

  def field_checks=(checks)
    super(Array(checks).map { |c| c.respond_to?(:to_h) ? c.to_h : c })
  end

  def record_decision(decision:, note:)
    update!(decision: decision, decision_note: note, decided_at: Time.current)
  end
end
