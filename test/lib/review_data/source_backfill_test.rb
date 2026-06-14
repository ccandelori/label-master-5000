# frozen_string_literal: true

require "test_helper"

class SourceBackfillTest < ActiveSupport::TestCase
  def create_application(serial:, batch:, filename:, bytes:)
    application = LabelApplication.new(
      batch: batch,
      channel: "submitted",
      serial_number: serial,
      beverage_type: "wine",
      brand_name: "BRAND #{serial}",
      applicant_name_address: "Example Winery, Napa, CA",
      net_contents: "750 mL"
    )
    application.artwork.attach(io: StringIO.new(bytes), filename: filename, content_type: "image/png")
    application.save!
    application
  end

  def run_backfill(dry_run:)
    io = StringIO.new
    result = ReviewData::SourceBackfill.new(io: io, dry_run: dry_run).run
    [ result, io.string ]
  end

  test "dry run reports source changes without persisting" do
    batch = Batch.create!(name: "TTB registry eval 2099-01-01")
    application = create_application(
      serial: "99023001000088", batch: batch, filename: "front.png", bytes: "front"
    )

    result, output = run_backfill(dry_run: true)

    assert_match(/dry run/, output)
    assert_equal "registry_eval", result[:batches].first.fetch(:to)
    assert_equal "registry_eval", result[:applications].first.fetch(:to)
    assert_predicate batch.reload, :batch_upload?
    assert_predicate application.reload, :manual?
  end

  test "persist classifies existing records and quarantines suspicious artwork" do
    eval_batch = Batch.create!(name: "TTB registry eval 2099-01-01")
    mutation_batch = Batch.create!(name: "Mutations of 99023001000088")
    seed_batch = Batch.create!(name: "TTB registry sample")
    eval_record = create_application(
      serial: "99023001000088", batch: eval_batch, filename: "back label.png", bytes: "back"
    )
    mutation = create_application(
      serial: "99023001000088-MUT-BRAND", batch: mutation_batch, filename: "front.png", bytes: "mut"
    )
    demo = create_application(
      serial: "DEMO-RETAKE", batch: seed_batch, filename: "bad.png", bytes: "demo"
    )
    duplicated = create_application(
      serial: "99023001000089", batch: eval_batch, filename: "front.png", bytes: "same"
    )
    duplicated.back_artwork.attach(duplicated.artwork.blob)
    duplicated.save!

    run_backfill(dry_run: false)

    assert_predicate eval_batch.reload, :registry_eval?
    assert_predicate mutation_batch.reload, :mutation?
    assert_predicate seed_batch.reload, :seed_sample?
    assert_predicate eval_record.reload, :registry_eval?
    assert_predicate mutation.reload, :mutation?
    assert_predicate demo.reload, :demo?
    assert_includes eval_record.quarantine_reasons, "primary_artwork_filename_indicates_back"
    assert_includes duplicated.reload.quarantine_reasons, "identical_front_back_artwork"
    assert duplicated.quarantined_at.present?
  end
end
