# frozen_string_literal: true

class Verification < ApplicationRecord
  belongs_to :label_application
  has_one :verification_attempt, dependent: :nullify

  # Live update for anyone watching the application page when a background
  # verification completes.
  after_create_commit :broadcast_result
  after_update_commit :broadcast_result, if: :result_changed?
  # History membership, ordering, and tab counts are all computed server-side,
  # so any verification event (new result, decision, undo) refreshes every
  # open history page via a debounced page-refresh broadcast; the page morphs.
  after_commit :broadcast_queue_refresh

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

  # A reject carries a draft rejection notice built from the cited findings;
  # generation is pure string assembly, so it happens inline without
  # slowing the decision down.
  def record_decision(decision:, note:)
    assign_attributes(decision: decision, decision_note: note, decided_at: Time.current)
    self.rejection_notice =
      decided_to_reject? ? RejectionNotice.generate(application: label_application, verification: self) : nil
    save!
  end

  def undo_decision
    update!(decision: nil, decision_note: nil, decided_at: nil, rejection_notice: nil)
  end

  private

  def result_changed?
    (previous_changes.keys & %w[overall_verdict field_checks extraction model_id latency_ms error_message]).any?
  end

  def broadcast_result
    broadcast_replace_to(
      label_application,
      target: "validation_status_header",
      partial: "label_applications/validation_status_header",
      locals: { application: label_application, verification: self, attempt: label_application.latest_verification_attempt }
    )
    broadcast_replace_to(
      label_application,
      target: "verification_panel",
      partial: "label_applications/verification_panel",
      locals: { application: label_application, verification: self, attempt: label_application.latest_verification_attempt }
    )
    broadcast_batch_row
  end

  def broadcast_queue_refresh
    broadcast_refresh_later_to :validation_history
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
