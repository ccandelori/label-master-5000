# frozen_string_literal: true

require "test_helper"

class BatchIngestTest < ActiveSupport::TestCase
  HEADER = "serial_number,beverage_type,brand_name,applicant_name_address,net_contents,image_filename"
  COLA_HEADER = "filename,brand_name,class_type,alcohol_content,net_contents,bottler_address,country_of_origin,fanciful_name"

  def csv(rows)
    ([ HEADER ] + rows).join("\n")
  end

  def cola_csv(rows)
    ([ COLA_HEADER ] + rows.map { |row| CSV.generate_line(row).strip }).join("\n")
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

  test "generic batch rows can reference a back label image" do
    header = "#{HEADER},back_image_filename"
    result = BatchIngest.parse(
      "#{header}\n26-1,spirits,Old Tom,Old Tom Co. KY,750 mL,front.png,back.png",
      %w[front.png back.png]
    )

    assert result.valid?, result.errors.map(&:message).join("\n")
    assert_equal "front.png", result.rows.first.image_filename
    assert_equal "back.png", result.rows.first.back_image_filename
  end

  test "missing required columns fail before row validation" do
    result = BatchIngest.parse("serial_number,brand_name\n26-1,Old Tom", %w[a.png])
    assert_not result.valid?
    assert_equal :missing_columns, result.errors.first.kind
    assert_match(/beverage_type/, result.errors.first.message)
  end

  test "cola shaped csv reports missing cola columns" do
    result = BatchIngest.parse("filename,brand_name\n2601,Old Tom", %w[2601-1.png])

    assert_not result.valid?
    assert_equal :missing_columns, result.errors.first.kind
    assert_match(/COLA sample/, result.errors.first.message)
    assert_match(/class_type/, result.errors.first.message)
  end

  test "cola sample csv maps application fields and manifest images" do
    serial = "26083001000106"
    manifest = JSON.generate([
      {
        "ttbId" => serial,
        "images" => [ "#{serial}-1.png", "#{serial}-2.png", "#{serial}-3.png" ]
      }
    ])

    result = BatchIngest.parse(
      cola_csv([
        [
          serial,
          "RANSOM RIDGE",
          "ROSE WINE",
          "",
          "",
          "MARTIN&#x27;S HONEY FARM AND MEADERY, LLC",
          "Product of France",
          "SPRING RELEASE"
        ]
      ]),
      [ "#{serial}-1.png", "#{serial}-2.png", "#{serial}-3.png" ],
      manifest_text: manifest
    )

    assert result.valid?, result.errors.map(&:message).join("\n")

    row = result.rows.first
    attributes = row.attributes
    assert_equal serial, attributes[:serial_number]
    assert_equal "wine", attributes[:beverage_type]
    assert_equal true, attributes[:imported]
    assert_equal "France", attributes[:country_of_origin]
    assert_equal "MARTIN'S HONEY FARM AND MEADERY, LLC", attributes[:applicant_name_address]
    assert_equal "SPRING RELEASE", attributes[:fanciful_name]
    assert_equal "ROSE WINE", attributes[:declared_class_type]
    assert_equal ColaSampleIngest::NET_CONTENTS_SENTINEL, attributes[:net_contents]
    assert_equal "#{serial}-1.png", row.image_filename
    assert_equal "#{serial}-2.png", row.back_image_filename
    assert_equal [ "#{serial}-3.png" ], row.auxiliary_image_filenames
  end

  test "cola sample csv infers images by serial when manifest is absent" do
    serial = "26076001000808"
    result = BatchIngest.parse(
      cola_csv([
        [ serial, "PINT & PLOW BREWING CO.", "MALT BEVERAGES SPECIALITIES - FLAVORED", "", "", "Pint & Plow", "", "" ]
      ]),
      [ "#{serial}-2.jpg", "#{serial}-1.jpg" ]
    )

    assert result.valid?, result.errors.map(&:message).join("\n")
    assert_equal "malt", result.rows.first.attributes[:beverage_type]
    assert_equal "#{serial}-1.jpg", result.rows.first.image_filename
    assert_equal "#{serial}-2.jpg", result.rows.first.back_image_filename
  end

  test "cola sample manifest missing uploaded images is a row error" do
    serial = "26078001000116"
    result = BatchIngest.parse(
      cola_csv([
        [ serial, "LATE CHECKOUT", "VODKA SPECIALTIES", "", "", "Valley Vodka", "Product of Poland", "" ]
      ]),
      [ "#{serial}-1.jpg" ],
      manifest_text: JSON.generate([
        { "ttbId" => serial, "images" => [ "#{serial}-1.jpg", "#{serial}-2.jpg" ] }
      ])
    )

    error = result.errors.find { |row_error| row_error.kind == :missing_image }
    assert_not result.valid?
    assert_equal 2, error.row_number
    assert_match(/#{serial}-2\.jpg/, error.message)
  end

  test "cola sample unknown class type is a row error" do
    serial = "26078001000713"
    result = BatchIngest.parse(
      cola_csv([
        [ serial, "BLACK FOREST", "KOMBUCHA", "", "", "Old Homestead", "", "" ]
      ]),
      [ "#{serial}-1.jpg" ]
    )

    assert result.errors.any? { |row_error| row_error.kind == :invalid_value && row_error.message.include?("class_type") }
  end

  test "cola sample malformed manifest is a global error" do
    result = BatchIngest.parse(
      cola_csv([
        [ "26054001000510", "DELISH", "TABLE FLAVORED WINE", "", "", "Buzzbox", "", "" ]
      ]),
      [ "26054001000510-1.jpg" ],
      manifest_text: "{"
    )

    assert_equal :malformed_manifest, result.errors.first.kind
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
    assert_no_match(/orphan/i, result.errors.map(&:message).join("\n"))
  end

  test "rows referencing missing back images fail with the row number and column" do
    header = "#{HEADER},back_image_filename"
    result = BatchIngest.parse(
      "#{header}\n26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png,missing-back.png",
      %w[a.png]
    )
    error = result.errors.find { |e| e.kind == :missing_image }

    assert_equal 2, error.row_number
    assert_match(/back_image_filename/, error.message)
    assert_match(/missing-back.png/, error.message)
  end

  test "orphan uploads are flagged" do
    result = BatchIngest.parse(csv([ "26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png" ]), %w[a.png extra.png])
    assert result.errors.any? { |e| e.kind == :orphan_image && e.message.include?("extra.png") }
  end

  test "duplicate uploaded filenames are flagged" do
    result = BatchIngest.parse(csv([ "26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png" ]), %w[a.png a.png])
    assert result.errors.any? { |e| e.kind == :duplicate_image }
  end

  test "duplicate row image references are flagged" do
    result = BatchIngest.parse(
      csv([ "26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png",
            "26-2,malt,Second Label,Second Co.,12 fl oz,a.png" ]),
      %w[a.png]
    )

    assert result.errors.any? { |e| e.kind == :duplicate_image_reference && e.message.include?("2, 3") }
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

  test "out of range alcohol content is a row error" do
    header = "#{HEADER},alcohol_content"
    result = BatchIngest.parse(
      "#{header}\n26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png,101",
      %w[a.png]
    )

    assert result.errors.any? { |e| e.kind == :invalid_value && e.message.include?("less than 100") }
  end

  test "invalid boolean literal is a row error" do
    header = "#{HEADER},contains_sulfites_10ppm"
    result = BatchIngest.parse(
      "#{header}\n26-1,wine,ABC,XYZ Napa CA,750 mL,a.png,maybe",
      %w[a.png]
    )

    assert result.errors.any? { |e| e.kind == :invalid_value && e.message.include?("contains_sulfites_10ppm") }
  end

  test "imported rows require country of origin before persistence" do
    header = "#{HEADER},imported"
    result = BatchIngest.parse(
      "#{header}\n26-1,spirits,Old Tom,Old Tom Co.,750 mL,a.png,true",
      %w[a.png]
    )

    assert result.errors.any? { |e| e.kind == :missing_value && e.message.include?("country_of_origin") }
  end

  test "invalid vintage year is a row error" do
    header = "#{HEADER},vintage_year"
    result = BatchIngest.parse(
      "#{header}\n26-1,wine,ABC,XYZ Napa CA,750 mL,a.png,2021.5",
      %w[a.png]
    )

    assert result.errors.any? { |e| e.kind == :invalid_value && e.message.include?("vintage_year") }
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

  test "false boolean literals cast correctly" do
    header = "#{HEADER},contains_sulfites_10ppm,imported"
    result = BatchIngest.parse(
      "#{header}\n26-1,wine,ABC,XYZ Napa CA,750 mL,a.png,no,false",
      %w[a.png]
    )

    attributes = result.rows.first.attributes
    assert_equal false, attributes[:contains_sulfites_10ppm]
    assert_equal false, attributes[:imported]
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
