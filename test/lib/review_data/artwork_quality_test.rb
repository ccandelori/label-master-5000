# frozen_string_literal: true

require "test_helper"

class ArtworkQualityTest < ActiveSupport::TestCase
  def application(serial:, source_kind:, filename:, bytes:)
    app = LabelApplication.new(
      channel: "submitted",
      source_kind: source_kind,
      serial_number: serial,
      beverage_type: "wine",
      brand_name: "BRAND #{serial}",
      applicant_name_address: "Example Winery, Napa, CA",
      net_contents: "750 mL"
    )
    app.artwork.attach(io: StringIO.new(bytes), filename: filename, content_type: "image/png")
    app.save!
    app
  end

  test "detects identical front and back artwork" do
    app = application(serial: "26-SAME", source_kind: "manual", filename: "front.png", bytes: "same")
    app.back_artwork.attach(app.artwork.blob)
    app.save!

    reasons = ReviewData::ArtworkQuality.reasons_for(
      application: app, source_kind: app.source_kind, shared_checksums: []
    )

    assert_includes reasons, "identical_front_back_artwork"
  end

  test "detects primary artwork that looks like a back label" do
    app = application(serial: "26-BACK", source_kind: "manual", filename: "back label.png", bytes: "back")

    reasons = ReviewData::ArtworkQuality.reasons_for(
      application: app, source_kind: app.source_kind, shared_checksums: []
    )

    assert_includes reasons, "primary_artwork_filename_indicates_back"
  end

  test "ignores intentional mutation artwork sharing" do
    app = application(serial: "26-MUT", source_kind: "mutation", filename: "back label.png", bytes: "back")
    app.back_artwork.attach(app.artwork.blob)
    app.save!

    reasons = ReviewData::ArtworkQuality.reasons_for(
      application: app, source_kind: app.source_kind, shared_checksums: [ app.artwork.blob.checksum ]
    )

    assert_empty reasons
  end

  test "finds shared checksums across distinct applications" do
    application(serial: "26-ONE", source_kind: "manual", filename: "one.png", bytes: "shared")
    second = application(serial: "26-TWO", source_kind: "registry_eval", filename: "two.png", bytes: "shared")

    reasons = ReviewData::ArtworkQuality.import_reasons_for(application: second)

    assert_includes reasons, "artwork_checksum_shared_across_applications"
  end
end
