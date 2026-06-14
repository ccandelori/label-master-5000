# frozen_string_literal: true

require "test_helper"

class PerformanceAttemptReportTest < ActiveSupport::TestCase
  def application(serial)
    LabelApplication.create!(
      serial_number: serial,
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    )
  end

  def verification(app, verdict, reused)
    app.verifications.create!(
      overall_verdict: verdict,
      field_checks: [],
      extraction_reused: reused,
      model_id: VerifierV2::MODEL_ID
    )
  end

  test "summarizes persisted attempt timing, verdicts, reuse, and errors" do
    first_app = application("REPORT-1")
    second_app = application("REPORT-2")
    first = first_app.verification_attempts.create!(queue_wait_ms: 50)
    first.finish_with!(
      verification: verification(first_app, "pass", false),
      stage_timings: { "ocr_ms" => 100, "rules_ms" => 20, "total_ms" => 150 }
    )
    second = second_app.verification_attempts.create!(queue_wait_ms: 150)
    second.finish_with!(
      verification: verification(second_app, "fail", true),
      stage_timings: { "ocr_ms" => 300, "rules_ms" => 40, "total_ms" => 450 }
    )
    error = second_app.verification_attempts.create!(queue_wait_ms: 20)
    error.fail_with!(
      error: Extraction::OcrError.new("ocr unavailable"),
      context: { "stage" => "ocr" },
      stage_timings: { "ocr_ms" => 10, "total_ms" => 25 }
    )

    report = Performance::AttemptReport.new(scope: VerificationAttempt.where(id: [ first.id, second.id, error.id ])).to_h

    assert_equal 3, report.fetch(:attempts)
    assert_equal 1, report.dig(:states, "passed")
    assert_equal 1, report.dig(:states, "failed")
    assert_equal 1, report.dig(:states, "error")
    assert_equal 1, report.dig(:verdicts, "pass")
    assert_equal 1, report.dig(:verdicts, "fail")
    assert_equal 50.0, report.dig(:queue_wait_ms, :p50)
    assert_equal 450.0, report.dig(:total_ms, :max)
    assert_equal 300.0, report.dig(:stages, "ocr_ms", :p95)
    assert_equal 1, report.dig(:extraction_reuse, :reused)
    assert_equal 1, report.dig(:errors, :by_class, "Extraction::OcrError")
  end
end
