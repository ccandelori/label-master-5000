# frozen_string_literal: true

class VerificationAttempt < ApplicationRecord
  STATES_BY_VERDICT = {
    "pass" => "passed",
    "pass_with_note" => "passed",
    "fail" => "failed",
    "needs_review" => "needs_review",
    "request_retake" => "needs_review",
    "error" => "error"
  }.freeze

  belongs_to :label_application
  belongs_to :verification, optional: true

  after_commit :broadcast_progress
  after_commit :refresh_batch_processing_state

  enum :state, {
    queued: "queued",
    processing: "processing",
    passed: "passed",
    failed: "failed",
    needs_review: "needs_review",
    error: "error"
  }, validate: true

  def start_processing!
    started_at = Time.current
    update!(
      state: "processing",
      processing_started_at: started_at,
      queue_wait_ms: elapsed_ms(created_at, started_at)
    )
  end

  def finish_with!(verification:, stage_timings:)
    update!(
      verification: verification,
      state: state_for(verification),
      processing_completed_at: Time.current,
      stage_timings: stage_timings
    )
  end

  def fail_with!(error:, context:, stage_timings:)
    update!(
      state: "error",
      processing_completed_at: Time.current,
      error_class: error.class.name,
      error_message: error.message.to_s.first(500),
      error_context: context,
      stage_timings: stage_timings
    )
  end

  def in_progress?
    queued? || processing?
  end

  private

  def state_for(verification)
    STATES_BY_VERDICT.fetch(verification.overall_verdict)
  end

  def elapsed_ms(started_at, finished_at)
    ((finished_at - started_at) * 1000).round
  end

  def broadcast_progress
    VerifierV2::ProgressReporter.broadcast_attempt(self)
  end

  def refresh_batch_processing_state
    label_application.batch&.refresh_processing_state!
  end
end
