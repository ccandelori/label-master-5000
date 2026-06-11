# frozen_string_literal: true

require "test_helper"

class RegionRefinerTest < ActiveSupport::TestCase
  def magick? = system("which magick > /dev/null 2>&1")

  def source(data)
    Extraction::ArtworkSource.new(data: data, content_type: "image/png", checksum: "test-checksum")
  end

  def word(text, x, y, w, h)
    Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: w, height: h)
  end

  class StubEngine
    def initialize(words:)
      @words = words
    end

    def read(data:, content_type:)
      [ Extraction::OcrClient::Page.new(number: 1, width: 999, height: 999, words: @words) ]
    end
  end

  # Returns nothing until the given read, simulating a text that only a
  # wider crop (a later ladder rung) brings into view.
  class DeafUntilEngine
    attr_reader :reads

    def initialize(words:, from_read:)
      @words = words
      @from_read = from_read
      @reads = 0
    end

    def read(data:, content_type:)
      @reads += 1
      visible = @reads >= @from_read ? @words : []
      [ Extraction::OcrClient::Page.new(number: 1, width: 999, height: 999, words: visible) ]
    end
  end

  def payload(field)
    { "image_width" => 800, "image_height" => 1000, "fields" => { "brand_name" => field } }
  end

  test "re-grounds a model-estimated box from a crop and maps coordinates back" do
    skip "imagemagick not available" unless magick?

    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    field = { "text" => "OLD TOM DISTILLERY", "bbox" => [ 100, 80, 350, 42 ],
              "bbox_source" => "model", "page" => 1 }
    # Crop rect: pad 20% of 350x42 -> [30, 71.6, 490, 58.8]. Words placed
    # at 3x crop scale so the mapped box lands on round-ish numbers.
    crop_words = [ word("OLD", 210, 25, 150, 90), word("TOM", 390, 25, 150, 90), word("DISTILLERY", 570, 25, 450, 90) ]

    out = Extraction::RegionRefiner.refine(
      payload: payload(field), sources_by_page: { 1 => source(data) },
      engine: StubEngine.new(words: crop_words), threshold: 0.8
    )

    refined = out["fields"]["brand_name"]
    assert_equal "ocr", refined["bbox_source"]
    assert_equal [ 800, 1000 ], refined["bbox_basis"]
    assert_equal [ 100, 80, 270, 30 ], refined["bbox"]
  end

  test "escalates through wider paddings when the tight crop misses" do
    skip "imagemagick not available" unless magick?

    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    field = { "text" => "OLD TOM DISTILLERY", "bbox" => [ 100, 80, 350, 42 ],
              "bbox_source" => "model", "page" => 1 }
    crop_words = [ word("OLD", 210, 25, 150, 90), word("TOM", 390, 25, 150, 90), word("DISTILLERY", 570, 25, 450, 90) ]
    # Reads 1-2 are rung one (normal + inverted); read 3 is the 0.6 rung,
    # whose rect is [0, 54.8, 660, 92.4] (left clamped to the image edge).
    engine = DeafUntilEngine.new(words: crop_words, from_read: 3)

    out = Extraction::RegionRefiner.refine(
      payload: payload(field), sources_by_page: { 1 => source(data) },
      engine: engine, threshold: 0.8
    )

    refined = out["fields"]["brand_name"]
    assert_equal 3, engine.reads
    assert_equal "ocr", refined["bbox_source"]
    assert_equal [ 70, 63, 270, 30 ], refined["bbox"]
  end

  test "a full-ladder miss is stamped and not re-attempted" do
    skip "imagemagick not available" unless magick?

    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    field = { "text" => "NOWHERE TEXT", "bbox" => [ 100, 80, 350, 42 ],
              "bbox_source" => "model", "page" => 1 }
    engine = DeafUntilEngine.new(words: [], from_read: 1)

    out = Extraction::RegionRefiner.refine(
      payload: payload(field), sources_by_page: { 1 => source(data) },
      engine: engine, threshold: 0.8
    )
    stamped = out["fields"]["brand_name"]
    assert_equal Extraction::RegionRefiner::ALGORITHM_VERSION, stamped["refine_attempted"]
    assert_equal "model", stamped["bbox_source"]
    first_pass_reads = engine.reads

    again = Extraction::RegionRefiner.refine(
      payload: { "image_width" => 800, "image_height" => 1000, "fields" => { "brand_name" => stamped } },
      sources_by_page: { 1 => source(data) }, engine: engine, threshold: 0.8
    )
    assert_equal stamped, again["fields"]["brand_name"]
    assert_equal first_pass_reads, engine.reads, "stamped field must not trigger new reads"
  end

  test "fields already grounded or without text stay untouched" do
    skip "imagemagick not available" unless magick?

    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    grounded = { "text" => "OLD TOM", "bbox" => [ 1, 2, 3, 4 ], "bbox_source" => "ocr", "page" => 1 }
    silent = { "text" => nil, "bbox" => [ 1, 2, 3, 4 ], "bbox_source" => "model", "page" => 1 }
    input = { "image_width" => 800, "image_height" => 1000,
              "fields" => { "brand_name" => grounded, "vintage" => silent } }

    out = Extraction::RegionRefiner.refine(
      payload: input, sources_by_page: { 1 => source(data) },
      engine: StubEngine.new(words: []), threshold: 0.8
    )

    assert_equal input, out
  end

  test "unreadable artwork leaves the payload unchanged" do
    field = { "text" => "OLD TOM", "bbox" => [ 1, 2, 3, 4 ], "bbox_source" => "model", "page" => 1 }
    input = payload(field)

    out = Extraction::RegionRefiner.refine(
      payload: input, sources_by_page: { 1 => source("not-an-image") },
      engine: StubEngine.new(words: []), threshold: 0.8
    )

    assert_equal input, out
  end
end
