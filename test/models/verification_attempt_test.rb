# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

class VerificationAttemptTest < ActiveSupport::TestCase
  def label_application(attrs)
    LabelApplication.create!({
      serial_number: "ATTEMPT-1",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    }.merge(attrs))
  end

  test "starts queued and records processing time" do
    application = label_application({})
    created_at = Time.zone.local(2026, 6, 13, 9, 0, 0)
    attempt = application.verification_attempts.create!(created_at: created_at, updated_at: created_at)

    travel_to created_at + 3.seconds do
      attempt.start_processing!
    end

    assert_predicate attempt, :processing?
    assert_equal 3000, attempt.queue_wait_ms
    assert_equal created_at + 3.seconds, attempt.processing_started_at
  end

  test "finishes with terminal state from verification verdict" do
    application = label_application({})
    attempt = application.verification_attempts.create!
    verification = application.verifications.create!(overall_verdict: "pass_with_note", field_checks: [])

    attempt.finish_with!(verification: verification, stage_timings: { "ocr_pages" => 421 })

    assert_predicate attempt, :passed?
    assert_equal verification, attempt.verification
    assert_equal({ "ocr_pages" => 421 }, attempt.stage_timings)
    assert_not_nil attempt.processing_completed_at
  end

  test "maps review and failure verdicts to attempt states" do
    application = label_application({})
    failed = application.verification_attempts.create!
    failed_verification = application.verifications.create!(overall_verdict: "fail", field_checks: [])
    review = application.verification_attempts.create!
    review_verification = application.verifications.create!(overall_verdict: "request_retake", field_checks: [])

    failed.finish_with!(verification: failed_verification, stage_timings: {})
    review.finish_with!(verification: review_verification, stage_timings: {})

    assert_predicate failed, :failed?
    assert_predicate review, :needs_review?
  end

  test "records operational errors with diagnostic context" do
    application = label_application({})
    attempt = application.verification_attempts.create!
    error = RuntimeError.new("OCR backend unavailable")

    attempt.fail_with!(error: error, context: { "stage" => "ocr" }, stage_timings: { "ocr_pages" => 1500 })

    assert_predicate attempt, :error?
    assert_equal "RuntimeError", attempt.error_class
    assert_equal "OCR backend unavailable", attempt.error_message
    assert_equal({ "stage" => "ocr" }, attempt.error_context)
    assert_equal({ "ocr_pages" => 1500 }, attempt.stage_timings)
    assert_not_nil attempt.processing_completed_at
  end

  test "in progress covers queued and processing states only" do
    application = label_application({})
    attempt = application.verification_attempts.create!

    assert_predicate attempt, :in_progress?

    attempt.start_processing!
    assert_predicate attempt, :in_progress?

    verification = application.verifications.create!(overall_verdict: "pass", field_checks: [])
    attempt.finish_with!(verification: verification, stage_timings: {})
    assert_not attempt.in_progress?
  end
end

class VerificationAttemptBroadcastTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  def label_application(attrs)
    LabelApplication.create!({
      serial_number: "ATTEMPT-BROADCAST-1",
      channel: "submitted",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    }.merge(attrs))
  end

  def drain_refresh_debounce
    Turbo::StreamsChannel.refresh_debouncer_for(:validation_history).wait
  end

  test "attempt state changes refresh history" do
    application = nil
    perform_enqueued_jobs { application = label_application({}); drain_refresh_debounce }
    attempt = nil
    perform_enqueued_jobs { attempt = application.verification_attempts.create!; drain_refresh_debounce }

    assert_turbo_stream_broadcasts :validation_history, count: 1 do
      perform_enqueued_jobs do
        attempt.start_processing!
        drain_refresh_debounce
      end
    end
  end

  test "batch attempt state changes replace row and progress" do
    batch = Batch.create!(name: "Broadcast batch", source_kind: "batch_upload", status: "processing", total_rows: 1)
    application = label_application(batch: batch, source_kind: "batch_upload")
    attempt = nil
    perform_enqueued_jobs { attempt = application.verification_attempts.create! }

    assert_turbo_stream_broadcasts batch, count: 2 do
      perform_enqueued_jobs { attempt.start_processing! }
    end
  end

  test "attempt state changes replace the application validation header and panel" do
    application = label_application({})
    attempt = nil
    perform_enqueued_jobs { attempt = application.verification_attempts.create! }

    assert_turbo_stream_broadcasts application, count: 2 do
      perform_enqueued_jobs { attempt.start_processing! }
    end
  end
end
