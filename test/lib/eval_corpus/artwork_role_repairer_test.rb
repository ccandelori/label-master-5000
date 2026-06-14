# frozen_string_literal: true

require "test_helper"

class ArtworkRoleRepairerTest < ActiveSupport::TestCase
  def application
    LabelApplication.create!(
      channel: "submitted",
      serial_number: "SWAP-1",
      brand_name: "SWAPPED",
      beverage_type: "wine",
      applicant_name_address: "Example Winery, Napa, CA",
      net_contents: "750 mL"
    )
  end

  test "repairs a clear filename-identified front back inversion" do
    record = application
    record.artwork.attach(io: StringIO.new("back-bytes"), filename: "label Back.png", content_type: "image/png")
    record.back_artwork.attach(io: StringIO.new("front-bytes"), filename: "label Front.png", content_type: "image/png")
    record.save!

    repaired = EvalCorpus::ArtworkRoleRepairer.new(
      scope: LabelApplication.where(id: record.id),
      io: StringIO.new,
      dry_run: false
    ).repair

    assert_equal 1, repaired
    assert_equal "label Front.png", record.reload.artwork.filename.to_s
    assert_equal "label Back.png", record.back_artwork.filename.to_s
  end

  test "leaves ambiguous filenames unchanged" do
    record = application
    record.artwork.attach(io: StringIO.new("a"), filename: "label-a.png", content_type: "image/png")
    record.back_artwork.attach(io: StringIO.new("b"), filename: "label-b.png", content_type: "image/png")
    record.save!

    repaired = EvalCorpus::ArtworkRoleRepairer.new(
      scope: LabelApplication.where(id: record.id),
      io: StringIO.new,
      dry_run: false
    ).repair

    assert_equal 0, repaired
    assert_equal "label-a.png", record.reload.artwork.filename.to_s
    assert_equal "label-b.png", record.back_artwork.filename.to_s
  end
end
