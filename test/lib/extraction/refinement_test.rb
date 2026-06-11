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

  # Answers each read with the page list registered for those bytes -
  # front and back blobs read differently, like real artwork.
  class PerBlobEngine
    def initialize(pages_by_data:)
      @pages_by_data = pages_by_data
    end

    def read(data:, content_type:)
      @pages_by_data.fetch(data)
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

  def sources_for(app)
    [ app.artwork, app.back_artwork ].select(&:attached?).map do |attachment|
      Extraction::ArtworkSource.new(
        data: attachment.download, content_type: attachment.content_type, checksum: attachment.blob.checksum
      )
    end
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
      raw: raw, artworks: sources_for(app), application: app
    )

    assert_equal "ocr", out.dig("fields", "brand_name", "bbox_source")
    assert_equal [ 100, 80, 140, 40 ], out.dig("fields", "brand_name", "bbox")
    assert_equal 1, OcrReading.where(engine_key: "test-v1").count, "page pool is cached"
  end

  test "a back label reads as page 2 and each blob caches under its own checksum" do
    app = application_with_artwork
    app.back_artwork.attach(io: StringIO.new("back-bytes"), filename: "back.png", content_type: "image/png")
    app.save!

    page = ->(words) do
      Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)
    end
    engine = PerBlobEngine.new(pages_by_data: {
      "label-bytes" => [ page.call([ Extraction::OcrClient::Word.new(text: "OLD TOM", x: 100, y: 80, width: 130, height: 40) ]) ],
      "back-bytes" => [ page.call([ Extraction::OcrClient::Word.new(text: "CONTAINS SULFITES", x: 50, y: 900, width: 200, height: 20) ]) ]
    })
    raw = { "image_width" => 800, "image_height" => 1000,
            "fields" => { "government_warning" => nil },
            "disclosures" => [ { "text" => "CONTAINS SULFITES", "bbox" => [ 1, 2, 3, 4 ], "page" => 2 } ] }

    out = refinement(engine).refine(raw: raw, artworks: sources_for(app), application: app)

    disclosure = out["disclosures"].first
    assert_equal "ocr", disclosure["bbox_source"], "page-2 element grounds against the renumbered back pool"
    assert_equal [ 50, 900, 200, 20 ], disclosure["bbox"]
    assert_equal 2, OcrReading.where(engine_key: "test-v1").count, "one cache row per blob"
    assert_equal [ app.artwork.blob.checksum, app.back_artwork.blob.checksum ].sort,
                 OcrReading.where(engine_key: "test-v1").pluck(:blob_checksum).sort
  end

  test "an OCR failure returns the raw payload unchanged" do
    app = application_with_artwork
    raw = { "fields" => { "brand_name" => { "text" => "OLD TOM", "bbox" => [ 1, 2, 3, 4 ], "page" => 1 } } }

    out = refinement(StubEngine.new(error: Extraction::OcrError.new("engine down"))).refine(
      raw: raw, artworks: sources_for(app), application: app
    )

    assert_equal raw, out
  end
end
