# frozen_string_literal: true

require "test_helper"

class BatchIngestTest < ActiveSupport::TestCase
  HEADER = "serial_number,beverage_type,brand_name,applicant_name_address,net_contents,image_filename"

  def csv(rows)
    ([ HEADER ] + rows).join("\n")
  end

  test "a clean batch parses into rows" do
    result = BatchIngest.parse(
      csv([ "26-1,spirits,Old Tom,Old Tom Co. KY,750 mL,a.png",
            "26-2,malt,Stone's Throw,STB Seattle WA,12 fl oz,b.png" ]),
      %w[a.png b.png]
    )
    assert result.valid?
    assert_equal 2, result.rows.size
    assert_equal "Old Tom", result.rows.first.attributes[:brand_name]
    assert_equal 2, result.rows.first.row_number
  end

  test "missing required columns fail before row validation" do
    result = BatchIngest.parse("serial_number,brand_name\n26-1,Old Tom", %w[a.png])
    assert_not result.valid?
    assert_equal :missing_columns, result.errors.first.kind
    assert_match(/beverage_type/, result.errors.first.message)
  end

  test "unknown columns are flagged" do
    result = BatchIngest.parse(
      "#{HEADER},flavor\n26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png,oaky",
      %w[a.png]
    )
    assert result.errors.any? { |e| e.kind == :unknown_columns }
  end

  test "rows referencing missing images fail with the row number" do
    result = BatchIngest.parse(csv([ "26-1,spirits,Old Tom,Old Tom Co.,750 mL,missing.png" ]), %w[a.png])
    error = result.errors.find { |e| e.kind == :missing_image }
    assert_equal 2, error.row_number
    assert_match(/missing.png/, error.message)
  end

  test "orphan uploads are flagged" do
    result = BatchIngest.parse(csv([ "26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png" ]), %w[a.png extra.png])
    assert result.errors.any? { |e| e.kind == :orphan_image && e.message.include?("extra.png") }
  end

  test "duplicate uploaded filenames are flagged" do
    result = BatchIngest.parse(csv([ "26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png" ]), %w[a.png a.png])
    assert result.errors.any? { |e| e.kind == :duplicate_image }
  end

  test "blank required values and bad types are row errors" do
    result = BatchIngest.parse(
      csv([ ",cider,Old Tom,Old Tom Co.,750 mL,a.png",
            "26-2,spirits,,Old Tom Co.,750 mL,a.png",
            "26-3,spirits,Old Tom,Old Tom Co.,750 mL,a.png" ]),
      %w[a.png]
    )
    kinds = result.errors.map(&:kind)
    assert_includes kinds, :missing_value
    assert_includes kinds, :invalid_value
    assert_equal 1, result.rows.size
  end

  test "non-numeric alcohol content is a row error" do
    header = "#{HEADER},alcohol_content"
    result = BatchIngest.parse(
      "#{header}\n26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png,forty-five",
      %w[a.png]
    )
    assert result.errors.any? { |e| e.kind == :invalid_value && e.message.include?("alcohol_content") }
  end

  test "wine and formula columns cast correctly" do
    header = "#{HEADER},varietals,vintage_year,contains_sulfites_10ppm,imported,country_of_origin"
    result = BatchIngest.parse(
      "#{header}\n26-1,wine,ABC,XYZ Napa CA,750 mL,a.png,Merlot; Syrah,2021,true,yes,France",
      %w[a.png]
    )
    attributes = result.rows.first.attributes
    assert_equal %w[Merlot Syrah], attributes[:varietals]
    assert_equal 2021, attributes[:vintage_year]
    assert_equal true, attributes[:contains_sulfites_10ppm]
    assert_equal true, attributes[:imported]
    assert_equal "France", attributes[:country_of_origin]
  end

  test "blank tri-state booleans stay unknown" do
    header = "#{HEADER},contains_sulfites_10ppm"
    result = BatchIngest.parse(
      "#{header}\n26-1,wine,ABC,XYZ Napa CA,750 mL,a.png,",
      %w[a.png]
    )
    assert_nil result.rows.first.attributes[:contains_sulfites_10ppm]
  end

  test "unreadable CSV is a single structured error" do
    result = BatchIngest.parse("\"unclosed", %w[a.png])
    assert_equal :malformed_csv, result.errors.last.kind
  end
end
