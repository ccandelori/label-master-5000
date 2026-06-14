# frozen_string_literal: true

require "test_helper"
require "fileutils"

class BatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def build_application(batch, row_number, brand_name)
    batch.label_applications.create!(
      row_number: row_number,
      serial_number: "26-#{row_number}",
      beverage_type: "spirits",
      imported: false,
      brand_name: brand_name,
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    )
  end

  def upload_image(name, bytes)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), "image/png", original_filename: name)
  end

  test "submit_to_ttb promotes only pre-review applications" do
    batch = Batch.create!(name: "June shipment", total_rows: 2)
    first = build_application(batch, 1, "FIRST")
    second = build_application(batch, 2, "SECOND")
    second.submitted!

    assert_equal 1, batch.submit_to_ttb
    assert_predicate first.reload, :submitted?
    assert_predicate second.reload, :submitted?
    assert_equal 0, batch.submit_to_ttb
  end

  test "retry_failed_verifications_later queues unchecked and error applications" do
    batch = Batch.create!(name: "June shipment", total_rows: 3)
    clean = build_application(batch, 1, "CLEAN")
    failed = build_application(batch, 2, "FAILED")
    build_application(batch, 3, "UNCHECKED")

    clean.verifications.create!(overall_verdict: "pass", field_checks: [])
    failed.verifications.create!(overall_verdict: "error", field_checks: [])

    assert_enqueued_jobs 2, only: VerifyLabelJob do
      assert_equal 2, batch.retry_failed_verifications_later(
        provider: nil,
        model: nil,
        mode: VerifyLabelJob::OCR_FIRST_MODE
      )
    end
    assert_predicate batch.reload, :processing?
    assert_not_nil batch.processing_started_at
    assert_nil batch.processing_completed_at
  end

  test "verify_later starts the batch and creates queued attempts before jobs run" do
    batch = Batch.create!(name: "June shipment", total_rows: 2, status: "pending")
    first = build_application(batch, 1, "FIRST")
    second = build_application(batch, 2, "SECOND")

    assert_enqueued_jobs 2, only: VerifyLabelJob do
      batch.verify_later(provider: nil, model: nil, mode: VerifyLabelJob::OCR_FIRST_MODE)
    end

    assert_predicate batch.reload, :processing?
    assert_not_nil batch.processing_started_at
    assert_nil batch.processing_completed_at
    assert_predicate first.verification_attempts.last, :queued?
    assert_predicate second.verification_attempts.last, :queued?
  end

  test "batch completes after every latest attempt reaches a terminal state" do
    batch = Batch.create!(name: "June shipment", total_rows: 2, status: "processing", processing_started_at: 1.minute.ago)
    first = build_application(batch, 1, "FIRST")
    second = build_application(batch, 2, "SECOND")
    first_attempt = first.verification_attempts.create!
    second_attempt = second.verification_attempts.create!

    first_verification = first.verifications.create!(overall_verdict: "pass", field_checks: [])
    first_attempt.finish_with!(verification: first_verification, stage_timings: {})

    assert_predicate batch.reload, :processing?
    assert_nil batch.processing_completed_at

    second_verification = second.verifications.create!(overall_verdict: "fail", field_checks: [])
    second_attempt.finish_with!(verification: second_verification, stage_timings: {})

    assert_predicate batch.reload, :completed?
    assert_not_nil batch.processing_completed_at
    assert_equal 2, batch.done_count
    assert_equal({ "passed" => 1, "failed" => 1 }, batch.attempt_state_counts)
  end

  test "create_from_ingest attaches front and back artwork" do
    row = BatchIngest::Row.new(
      row_number: 2,
      image_filename: "front.png",
      back_image_filename: "back.png",
      auxiliary_image_filenames: [],
      attributes: {
        serial_number: "26-1",
        beverage_type: "wine",
        imported: false,
        brand_name: "RANSOM RIDGE",
        fanciful_name: nil,
        applicant_name_address: "Martin's Honey Farm",
        alcohol_content: nil,
        net_contents: "750 mL",
        country_of_origin: nil,
        container_embossed_info: nil,
        varietals: [],
        appellation: nil,
        vintage_year: nil,
        declared_class_type: "ROSE WINE",
        actual_alcohol_content: nil,
        contains_fd_c_yellow_5: nil,
        contains_cochineal_carmine: nil,
        contains_sulfites_10ppm: nil,
        contains_saccharin: nil,
        contains_aspartame: nil,
        contains_added_coloring: nil
      }
    )

    batch = Batch.create_from_ingest!(
      name: "COLA samples",
      rows: [ row ],
      images: [ upload_image("front.png", "front-bytes"), upload_image("back.png", "back-bytes") ]
    )

    application = batch.label_applications.first
    assert_predicate batch, :batch_upload?
    assert_predicate application, :batch_upload?
    assert_equal "front.png", application.artwork.filename.to_s
    assert_equal "back.png", application.back_artwork.filename.to_s
  end

  test "seed_application_pdfs imports repo-owned application PDFs idempotently" do
    Dir.mktmpdir do |dir|
      source_dir = Rails.root.join("downloads/ttb_cola_approved_applications_2026-06-13")
      pdf_name = "26098001000597__HUGO_S_COCKTAILS.pdf"
      manifest_record = JSON.parse(source_dir.join("manifest.json").read)
                            .find { |record| record.fetch("ttbId") == "26098001000597" }
      manifest_record["pdfPath"] = File.join(dir, pdf_name)
      FileUtils.cp(source_dir.join(pdf_name), File.join(dir, pdf_name))
      File.write(File.join(dir, "manifest.json"), JSON.pretty_generate([ manifest_record ]))

      assert_difference -> { Batch.count }, 1 do
        @batch = Batch.seed_application_pdfs!(dir: Pathname(dir))
      end

      assert_no_difference -> { Batch.count } do
        assert_equal @batch, Batch.seed_application_pdfs!(dir: Pathname(dir))
      end

      application = @batch.label_applications.first
      assert_predicate @batch, :seed_application_pdf?
      assert_predicate @batch, :pending?
      assert_equal "TTB approved application PDFs", @batch.name
      assert_equal 1, @batch.total_rows
      assert_predicate application, :seed_application_pdf?
      assert_predicate application, :submitted?
      assert_equal "HUGO'S COCKTAILS", application.brand_name
      assert_predicate application.application_pdf, :attached?
      assert_predicate application.artwork, :attached?

      application.update!(serial_number: "WRONG", brand_name: "WRONG")
      Batch.seed_application_pdfs!(dir: Pathname(dir))

      application = @batch.label_applications.reload.first
      assert_equal "260371", application.serial_number
      assert_equal "HUGO'S COCKTAILS", application.brand_name
    end
  end

  test "results_csv includes verdicts, decisions, and cited findings" do
    batch = Batch.create!(name: "June shipment", total_rows: 2)
    flagged = build_application(batch, 1, "FLAGGED")
    pending = build_application(batch, 2, "PENDING")

    verification = flagged.verifications.create!(
      overall_verdict: "fail",
      decision: "reject",
      field_checks: [
        {
          field: "brand_name",
          verdict: "fail",
          expected: "FLAGGED",
          extracted: "FL4GGED",
          note: "Brand differs",
          citation: "27 CFR 5.63"
        }
      ]
    )
    verification.record_decision(decision: "reject", note: nil)

    csv = batch.results_csv

    assert_match(/row,serial_number,brand_name/, csv)
    assert_match(/26-1,FLAGGED,spirits,fail,reject/, csv)
    assert_match(/brand_name: Brand differs \(27 CFR 5.63\)/, csv)
    assert_match(/26-2,PENDING,spirits,pending/, csv)
    assert_predicate pending, :pre_review?
  end
end
