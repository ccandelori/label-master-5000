# frozen_string_literal: true

require "test_helper"

class FieldCropsControllerTest < ActionDispatch::IntegrationTest
  def magick? = system("which magick > /dev/null 2>&1")

  def create_application_with_artwork
    app = LabelApplication.new(
      channel: "submitted", serial_number: "26-CROP", beverage_type: "spirits",
      imported: false, brand_name: "OLD TOM DISTILLERY",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0, net_contents: "750 mL"
    )
    app.artwork.attach(
      io: File.open(Rails.root.join("test/fixtures/files/ocr_label.png")),
      filename: "label.png", content_type: "image/png"
    )
    app.save!
    app
  end

  def add_verification(app, fields:)
    app.verifications.create!(
      overall_verdict: "pass", field_checks: [],
      extraction: { "image_width" => 800, "image_height" => 1000, "fields" => fields }
    )
  end

  test "serves a png crop for a located field" do
    skip "imagemagick not available" unless magick?

    app = create_application_with_artwork
    add_verification(app, fields: {
      "brand_name" => { "text" => "OLD TOM DISTILLERY", "bbox" => [ 100, 80, 350, 42 ],
                        "bbox_source" => "ocr", "page" => 1 }
    })

    get label_application_field_crop_path(app, field: "brand_name")
    assert_response :success
    assert_equal "image/png", response.media_type
    assert response.body.bytesize.positive?
  end

  test "unknown fields and unlocated fields are not found" do
    app = create_application_with_artwork
    add_verification(app, fields: { "brand_name" => { "text" => "X", "bbox" => nil, "page" => 1 } })

    get label_application_field_crop_path(app, field: "brand_name")
    assert_response :not_found

    get label_application_field_crop_path(app, field: "not_a_field")
    assert_response :not_found
  end
end
