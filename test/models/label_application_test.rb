# frozen_string_literal: true

require "test_helper"

class LabelApplicationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def valid_application(attrs)
    LabelApplication.new({
      serial_number: "26-1042",
      beverage_type: "spirits",
      imported: false,
      brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0,
      net_contents: "750 mL"
    }.merge(attrs))
  end

  test "valid with required COLA fields" do
    assert_predicate valid_application({}), :valid?
  end

  test "requires serial number, brand name, applicant, net contents" do
    %i[serial_number brand_name applicant_name_address net_contents].each do |field|
      app = valid_application(field => nil)
      assert_not app.valid?, "expected #{field} to be required"
      assert app.errors.key?(field)
    end
  end

  test "rejects unknown beverage type at assignment" do
    assert_raises(ArgumentError) { valid_application(beverage_type: "cider") }
  end

  test "imported products require a country of origin" do
    app = valid_application(imported: true, country_of_origin: nil)
    assert_not app.valid?
    assert app.errors.key?(:country_of_origin)

    app.country_of_origin = "Scotland"
    assert_predicate app, :valid?
  end

  test "alcohol content is optional but must be sane when present" do
    assert_predicate valid_application(alcohol_content: nil), :valid?
    assert_not valid_application(alcohol_content: 250).valid?
  end

  test "vintage year bounds" do
    assert_predicate valid_application(vintage_year: 2024), :valid?
    assert_not valid_application(vintage_year: 1850).valid?
  end

  test "formula_provided? reflects optional formula section" do
    assert_not valid_application({}).formula_provided?
    assert valid_application(actual_alcohol_content: 45.2).formula_provided?
    assert valid_application(contains_fd_c_yellow_5: false).formula_provided?
  end

  test "verify_later enqueues the verification job with model override" do
    app = valid_application({})
    app.save!

    assert_difference -> { app.verification_attempts.count } do
      app.verify_later(provider: "openai", model: "gpt-4.1-mini", mode: nil)
    end

    attempt = app.verification_attempts.last
    assert_predicate attempt, :queued?
    assert_enqueued_with(
      job: VerifyLabelJob,
      args: [ app.id, "openai", "gpt-4.1-mini", nil, attempt.id ],
      priority: VerifyLabelJob::DEFAULT_PRIORITY
    )
  end

  test "latest verification attempt returns the newest run" do
    app = valid_application({})
    app.save!
    old_attempt = app.verification_attempts.create!
    new_attempt = app.verification_attempts.create!

    assert_equal new_attempt, app.latest_verification_attempt
    assert_not_equal old_attempt, app.latest_verification_attempt
  end

  test "submit_to_ttb promotes pre-review applications once" do
    app = valid_application({})
    app.save!

    assert app.submit_to_ttb
    assert_predicate app, :submitted?
    assert_not app.submit_to_ttb
  end

  test "reviewer visibility requires production source and no quarantine" do
    manual = valid_application(channel: "submitted", source_kind: "manual")
    eval_record = valid_application(
      channel: "submitted", source_kind: "registry_eval", serial_number: "26-EVAL"
    )
    quarantined = valid_application(
      channel: "submitted", source_kind: "batch_upload", serial_number: "26-QUAR"
    )
    manual.save!
    eval_record.save!
    quarantined.save!
    quarantined.quarantine!(reasons: [ "identical_front_back_artwork" ])

    assert_predicate manual, :reviewer_visible?
    assert_not eval_record.reviewer_visible?
    assert_not quarantined.reviewer_visible?
    assert_equal [ manual ], LabelApplication.reviewer_visible.to_a
  end

  test "validation history includes real runs but not sample templates" do
    manual = valid_application(channel: "pre_review", source_kind: "manual", serial_number: "26-MANUAL")
    pdf_upload = valid_application(channel: "pre_review", source_kind: "application_pdf_upload", serial_number: "26-PDF")
    sample = valid_application(channel: "pre_review", source_kind: "seed_application_pdf", serial_number: "26-SAMPLE")
    registry_eval = valid_application(channel: "pre_review", source_kind: "registry_eval", serial_number: "26-EVAL")
    quarantined = valid_application(channel: "pre_review", source_kind: "manual", serial_number: "26-QUAR")
    manual.save!
    pdf_upload.save!
    sample.save!
    registry_eval.save!
    quarantined.save!
    quarantined.quarantine!(reasons: [ "sample quarantine" ])

    history = LabelApplication.validation_history_visible.to_a

    assert_includes history, manual
    assert_includes history, pdf_upload
    assert_not_includes history, sample
    assert_not_includes history, registry_eval
    assert_not_includes history, quarantined
    assert_predicate manual, :validation_history_visible?
    assert_not sample.validation_history_visible?
  end

  test "validation samples include seeded templates only" do
    sample = valid_application(channel: "pre_review", source_kind: "seed_application_pdf", serial_number: "26-SAMPLE")
    manual = valid_application(channel: "pre_review", source_kind: "manual", serial_number: "26-MANUAL")
    quarantined_sample = valid_application(channel: "pre_review", source_kind: "seed_sample", serial_number: "26-QUAR")
    sample.save!
    manual.save!
    quarantined_sample.save!
    quarantined_sample.quarantine!(reasons: [ "bad sample" ])

    samples = LabelApplication.validation_samples.to_a

    assert_includes samples, sample
    assert_not_includes samples, manual
    assert_not_includes samples, quarantined_sample
  end

  test "build_validation_copy creates a fresh manual validation from a sample" do
    sample = valid_application(
      channel: "pre_review",
      source_kind: "seed_application_pdf",
      serial_number: "26-SAMPLE",
      brand_name: "SAMPLE BRAND",
      fanciful_name: "FANCY SAMPLE",
      varietals: [ "Riesling" ],
      contains_added_coloring: false
    )
    sample.save!
    sample.artwork.attach(
      io: StringIO.new(File.binread(Rails.root.join("test/fixtures/files/label.png"))),
      filename: "label.png",
      content_type: "image/png"
    )

    copy = sample.build_validation_copy
    copy.save!

    assert_not_equal sample.id, copy.id
    assert_predicate copy, :pre_review?
    assert_equal "manual", copy.source_kind
    assert_equal "26-SAMPLE", copy.serial_number
    assert_equal "SAMPLE BRAND", copy.brand_name
    assert_equal "FANCY SAMPLE", copy.fanciful_name
    assert_equal [ "Riesling" ], copy.varietals
    assert_equal false, copy.contains_added_coloring
    assert_equal sample.artwork.blob, copy.artwork.blob
  end

  test "unchecked_or_error? follows the latest verification" do
    app = valid_application({})
    app.save!
    assert_predicate app, :unchecked_or_error?

    app.verifications.create!(overall_verdict: "pass", field_checks: [])
    assert_not app.unchecked_or_error?

    app.verifications.create!(overall_verdict: "error", field_checks: [])
    assert_predicate app, :unchecked_or_error?
  end

  test "review_verification follows the latest verification" do
    app = valid_application({})
    app.save!
    app.verifications.create!(
      overall_verdict: "pass", field_checks: [], model_id: "default-model",
      created_at: 2.minutes.ago
    )
    latest = app.verifications.create!(
      overall_verdict: "fail", field_checks: [], model_id: "comparison-model",
      created_at: 1.minute.ago
    )

    assert_equal latest, app.review_verification
  end

  test "artwork accepts allowed content types" do
    app = valid_application({})
    app.artwork.attach(
      io: StringIO.new("fake-png-bytes"), filename: "label.png", content_type: "image/png"
    )
    assert_predicate app, :valid?
  end

  test "artwork rejects disallowed content types" do
    app = valid_application({})
    app.artwork.attach(
      io: StringIO.new("plain text"), filename: "label.txt", content_type: "text/plain"
    )
    assert_not app.valid?
    assert app.errors.key?(:artwork)
  end

  test "back artwork accepts images only" do
    app = valid_application({})
    app.artwork.attach(io: StringIO.new("front"), filename: "front.png", content_type: "image/png")
    app.back_artwork.attach(io: StringIO.new("back"), filename: "back.png", content_type: "image/png")
    assert_predicate app, :valid?

    pdf_back = valid_application({})
    pdf_back.artwork.attach(io: StringIO.new("front"), filename: "front.png", content_type: "image/png")
    pdf_back.back_artwork.attach(io: StringIO.new("%PDF"), filename: "back.pdf", content_type: "application/pdf")
    assert_not pdf_back.valid?
    assert pdf_back.errors.key?(:back_artwork)
  end

  test "back artwork cannot accompany PDF front artwork" do
    app = valid_application({})
    app.artwork.attach(io: StringIO.new("%PDF"), filename: "label.pdf", content_type: "application/pdf")
    app.back_artwork.attach(io: StringIO.new("back"), filename: "back.png", content_type: "image/png")

    assert_not app.valid?
    assert_match(/cannot accompany PDF/, app.errors[:back_artwork].join)
  end
end
