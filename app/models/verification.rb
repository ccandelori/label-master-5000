# frozen_string_literal: true

class Verification < ApplicationRecord
  belongs_to :label_application

  # Live update for anyone watching the application page when a background
  # verification completes.
  after_create_commit :broadcast_result

  enum :overall_verdict, {
    pass: "pass",
    pass_with_note: "pass_with_note",
    fail: "fail",
    needs_review: "needs_review",
    request_retake: "request_retake",
    error: "error"
  }, validate: true

  scope :completed, -> { where.not(overall_verdict: "error") }
  scope :with_extraction, -> { where.not(extraction: nil) }

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

  private

  def broadcast_result
    broadcast_replace_to(
      label_application,
      target: "verification_panel",
      partial: "label_applications/verification_panel",
      locals: { application: label_application, verification: self }
    )
    broadcast_batch_row
  end

  def broadcast_batch_row
    batch = label_application.batch
    return if batch.nil?

    broadcast_replace_to(
      batch,
      target: "batch_row_#{label_application_id}",
      partial: "batches/row",
      locals: { application: label_application, verification: self }
    )
    broadcast_replace_to(
      batch,
      target: "batch_progress",
      partial: "batches/progress",
      locals: { batch: batch }
    )
  end
end
