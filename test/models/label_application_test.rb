# frozen_string_literal: true

require "test_helper"

class LabelApplicationTest < ActiveSupport::TestCase
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
