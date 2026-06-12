# frozen_string_literal: true

require "test_helper"

class MutatorTest < ActiveSupport::TestCase
  def source_application
    app = LabelApplication.new(
      serial_number: "EVAL-1", brand_name: "OLD TOM", fanciful_name: "WINTER CUT",
      beverage_type: "spirits", imported: true, country_of_origin: "Chile",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0, net_contents: "750 mL", channel: "submitted"
    )
    app.artwork.attach(io: StringIO.new("front-bytes"), filename: "front.png", content_type: "image/png")
    app.back_artwork.attach(io: StringIO.new("back-bytes"), filename: "back.png", content_type: "image/png")
    app.save!
    app
  end

  test "creates one known-bad clone per expressible mutation, sharing artwork blobs" do
    source = source_application
    created = EvalCorpus::Mutator.mutate(source, io: StringIO.new)

    assert_equal %w[BRAND NET ABV FANCIFUL ORIGIN].sort,
                 created.map { |c| c.serial_number[/MUT-(\w+)\z/, 1] }.sort

    brand = created.find { |c| c.serial_number.end_with?("-MUT-BRAND") }
    assert_equal "OLD TOM RESERVE", brand.brand_name
    assert_equal source.artwork.blob.checksum, brand.artwork.blob.checksum, "artwork blob is shared, not copied"
    assert_equal source.artwork.blob.id, brand.artwork.blob.id
    assert_equal source.back_artwork.blob.id, brand.back_artwork.blob.id

    net = created.find { |c| c.serial_number.end_with?("-MUT-NET") }
    assert_equal "1 L", net.net_contents, "750 mL swaps to a different legal size"

    origin = created.find { |c| c.serial_number.end_with?("-MUT-ORIGIN") }
    assert_equal "Portugal", origin.country_of_origin

    abv = created.find { |c| c.serial_number.end_with?("-MUT-ABV") }
    assert_equal 50.0, abv.alcohol_content
  end

  test "is idempotent by serial and skips inexpressible mutations" do
    source = source_application
    source.update!(imported: false, country_of_origin: nil, alcohol_content: nil)

    first = EvalCorpus::Mutator.mutate(source, io: StringIO.new)
    assert_equal %w[BRAND FANCIFUL NET].sort, first.map { |c| c.serial_number[/MUT-(\w+)\z/, 1] }.sort,
                 "no ORIGIN without an import, no ABV without a declared content"

    again = EvalCorpus::Mutator.mutate(source, io: StringIO.new)
    assert_empty again
  end
end
