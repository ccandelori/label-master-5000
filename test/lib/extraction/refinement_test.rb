# frozen_string_literal: true

require "test_helper"

class RefinementTest < ActiveSupport::TestCase
  class StubEngine
    def initialize(pages: [], error: nil)
      @pages = pages
      @error = error
    end

    def read(data:, content_type:)
      raise @error if @error

      @pages
    end
  end

  def application_with_artwork
    app = LabelApplication.create!(
      serial_number: "REF-1", brand_name: "OLD TOM", beverage_type: "spirits",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45.0, net_contents: "750 mL"
    )
    app.artwork.attach(io: StringIO.new("label-bytes"), filename: "label.png", content_type: "image/png")
    app.save!
    app
  end

  def refinement(engine)
    Extraction::Refinement.new(engine: engine, engine_key: "test-v1", threshold: 0.8)
  end

  test "grounds the payload against the engine's pages and caches the pool" do
    app = application_with_artwork
    pages = [ Extraction::OcrClient::Page.new(
      number: 1, width: 800, height: 1000,
      words: [ Extraction::OcrClient::Word.new(text: "OLD", x: 100, y: 80, width: 60, height: 40),
               Extraction::OcrClient::Word.new(text: "TOM", x: 170, y: 80, width: 70, height: 40) ]
    ) ]
    raw = { "image_width" => 800, "image_height" => 1000,
            "fields" => { "brand_name" => { "text" => "OLD TOM", "bbox" => [ 1, 2, 3, 4 ], "page" => 1 } } }

    out = refinement(StubEngine.new(pages: pages)).refine(
      raw: raw, data: "label-bytes", content_type: "image/png", application: app
    )

    assert_equal "ocr", out.dig("fields", "brand_name", "bbox_source")
    assert_equal [ 100, 80, 140, 40 ], out.dig("fields", "brand_name", "bbox")
    assert_equal 1, OcrReading.where(engine_key: "test-v1").count, "page pool is cached"
  end

  test "an OCR failure returns the raw payload unchanged" do
    app = application_with_artwork
    raw = { "fields" => { "brand_name" => { "text" => "OLD TOM", "bbox" => [ 1, 2, 3, 4 ], "page" => 1 } } }

    out = refinement(StubEngine.new(error: Extraction::OcrError.new("engine down"))).refine(
      raw: raw, data: "label-bytes", content_type: "image/png", application: app
    )

    assert_equal raw, out
  end
end
