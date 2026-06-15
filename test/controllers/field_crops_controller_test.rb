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

  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous_cache
  end

  def with_image_variant_method(method_name, replacement)
    original = Extraction::ImageVariants.method(method_name)
    Extraction::ImageVariants.define_singleton_method(method_name, &replacement)
    yield
  ensure
    Extraction::ImageVariants.define_singleton_method(method_name) do |*args, **kwargs|
      original.call(*args, **kwargs)
    end
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

  test "a model-estimated region serves no crop" do
    app = create_application_with_artwork
    add_verification(app, fields: {
      "brand_name" => { "text" => "OLD TOM DISTILLERY", "bbox" => [ 100, 80, 350, 42 ],
                        "bbox_source" => "model", "page" => 1 }
    })

    get label_application_field_crop_path(app, field: "brand_name")
    assert_response :not_found, "cutting pixels from an estimate manufactures evidence"
  end

  test "caches generated crops for repeated identical requests" do
    app = create_application_with_artwork
    add_verification(app, fields: {
      "brand_name" => { "text" => "OLD TOM DISTILLERY", "bbox" => [ 100, 80, 350, 42 ],
                        "bbox_source" => "ocr", "bbox_basis" => [ 800, 1000 ], "page" => 1 }
    })
    crop_calls = 0

    with_memory_cache do
      with_image_variant_method(:dimensions, ->(_data) { [ 800, 1000 ] }) do
        with_image_variant_method(:crop, ->(_data, rect:, upscale_factor:) {
          crop_calls += 1
          "png-#{rect.join("-")}-#{upscale_factor}"
        }) do
          2.times do
            get label_application_field_crop_path(app, field: "brand_name")

            assert_response :success
            assert_equal "image/png", response.media_type
            assert_match(/^png-/, response.body)
          end
        end
      end
    end

    assert_equal 1, crop_calls
  end

  test "unknown fields and unlocated fields are not found" do
    app = create_application_with_artwork
    add_verification(app, fields: { "brand_name" => { "text" => "X", "bbox" => nil, "page" => 1 } })

    get label_application_field_crop_path(app, field: "brand_name")
    assert_response :not_found

    get label_application_field_crop_path(app, field: "not_a_field")
    assert_response :not_found
  end

  test "a page-2 field crops from the back label and 404s without one" do
    skip "imagemagick not available" unless magick?

    app = create_application_with_artwork
    add_verification(app, fields: {
      "government_warning" => { "text" => "GOVERNMENT WARNING...", "bbox" => [ 100, 80, 350, 42 ],
                                "bbox_source" => "ocr", "bbox_basis" => [ 800, 1000 ], "page" => 2 }
    })

    get label_application_field_crop_path(app, field: "government_warning")
    assert_response :not_found, "no back label attached"

    app.back_artwork.attach(
      io: File.open(Rails.root.join("test/fixtures/files/ocr_label.png")),
      filename: "back.png", content_type: "image/png"
    )
    app.save!

    get label_application_field_crop_path(app, field: "government_warning")
    assert_response :success
    assert_equal "image/png", response.media_type
  end
end
