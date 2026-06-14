# frozen_string_literal: true

module VerifierV2
  # Broadcast and instrumentation boundary for attempt progress. Attempt
  # state changes update user-facing streams; stage events stay as
  # notifications so observability can subscribe without coupling to a UI.
  module ProgressReporter
    EVENT_NAME = "verification.progress.label_verifier"

    module_function

    def broadcast_attempt(attempt)
      application = attempt.label_application
      verification = application.latest_verification
      broadcast_application(application: application, verification: verification, attempt: attempt)
      broadcast_batch(application: application, verification: verification)
      Turbo::StreamsChannel.broadcast_refresh_later_to(:validation_history)
    end

    def stage_started(attempt:, stage:)
      ActiveSupport::Notifications.instrument(
        EVENT_NAME,
        event: "stage_started",
        stage: stage,
        verification_attempt_id: attempt.id,
        label_application_id: attempt.label_application_id
      )
    end

    def stage_finished(attempt:, stage:, duration_ms:)
      ActiveSupport::Notifications.instrument(
        EVENT_NAME,
        event: "stage_finished",
        stage: stage,
        duration_ms: duration_ms,
        verification_attempt_id: attempt.id,
        label_application_id: attempt.label_application_id
      )
    end

    def broadcast_application(application:, verification:, attempt:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        application,
        target: "validation_status_header",
        partial: "label_applications/validation_status_header",
        locals: { application: application, verification: verification, attempt: attempt }
      )
      Turbo::StreamsChannel.broadcast_replace_later_to(
        application,
        target: "verification_panel",
        partial: "label_applications/verification_panel",
        locals: { application: application, verification: verification, attempt: attempt }
      )
    end

    def broadcast_batch(application:, verification:)
      batch = application.batch
      return if batch.nil?

      Turbo::StreamsChannel.broadcast_replace_later_to(
        batch,
        target: "batch_row_#{application.id}",
        partial: "batches/row",
        locals: { application: application, verification: verification }
      )
      Turbo::StreamsChannel.broadcast_replace_later_to(
        batch,
        target: "batch_progress",
        partial: "batches/progress",
        locals: { batch: batch }
      )
    end
  end
end
