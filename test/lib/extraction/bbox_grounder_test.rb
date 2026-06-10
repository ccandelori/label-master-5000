# frozen_string_literal: true

require "test_helper"

class BboxGrounderTest < ActiveSupport::TestCase
  THRESHOLD = 0.8

  def word(text, x, y, width, height)
    Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: width, height: height)
  end

  def page(words, number: 1, width: 800, height: 1000)
    Extraction::OcrClient::Page.new(number: number, width: width, height: height, words: words)
  end

  def payload(fields: {}, varietals: [], disclosures: [])
    {
      "legible" => true,
      "confidence" => 0.9,
      "image_width" => 640,
      "image_height" => 800,
      "fields" => fields,
      "varietals" => varietals,
      "disclosures" => disclosures
    }
  end

  def field(text, bbox: [ 10, 10, 50, 10 ], page: 1)
    { "text" => text, "bbox" => bbox, "page" => page, "confidence" => 0.9 }
  end

  def ground(payload, pages)
    Extraction::BboxGrounder.ground(payload: payload, pages: pages, threshold: THRESHOLD)
  end

  test "exact match replaces bbox with the union of matched word boxes" do
    words = [
      word("OLD", 100, 80, 60, 40),
      word("TOM", 170, 80, 70, 40),
      word("DISTILLERY", 250, 80, 200, 42),
      word("750", 300, 600, 40, 20),
      word("mL", 345, 600, 30, 20)
    ]
    result = ground(payload(fields: { "brand_name" => field("OLD TOM DISTILLERY") }), [ page(words) ])

    grounded = result["fields"]["brand_name"]
    assert_equal [ 100, 80, 350, 42 ], grounded["bbox"]
    assert_equal [ 800, 1000 ], grounded["bbox_basis"]
    assert_equal "ocr", grounded["bbox_source"]
  end

  test "matches despite OCR character errors, punctuation, and case" do
    words = [ word("0ld", 10, 20, 30, 10), word("T0M", 45, 20, 30, 10), word("Distillery!", 80, 20, 60, 10) ]
    result = ground(payload(fields: { "brand_name" => field("OLD TOM DISTILLERY") }), [ page(words) ])

    grounded = result["fields"]["brand_name"]
    assert_equal "ocr", grounded["bbox_source"]
    assert_equal [ 10, 20, 130, 10 ], grounded["bbox"]
  end

  test "keeps the model box when no window reaches the threshold" do
    words = [ word("COMPLETELY", 10, 20, 50, 10), word("UNRELATED", 70, 20, 50, 10) ]
    result = ground(payload(fields: { "brand_name" => field("OLD TOM DISTILLERY") }), [ page(words) ])

    grounded = result["fields"]["brand_name"]
    assert_equal [ 10, 10, 50, 10 ], grounded["bbox"]
    assert_equal "model", grounded["bbox_source"]
    assert_nil grounded["bbox_basis"]
  end

  test "selects the matching region rather than a partial early occurrence" do
    words = [
      word("OLD", 10, 20, 30, 10), word("FASHIONED", 45, 20, 60, 10),
      word("OLD", 10, 300, 30, 10), word("TOM", 45, 300, 30, 10), word("DISTILLERY", 80, 300, 60, 10)
    ]
    result = ground(payload(fields: { "brand_name" => field("OLD TOM DISTILLERY") }), [ page(words) ])

    assert_equal [ 10, 300, 130, 10 ], result["fields"]["brand_name"]["bbox"]
  end

  test "unions word boxes across wrapped lines" do
    words = [
      word("CONTAINS", 100, 500, 80, 12),
      word("SULFITES", 100, 516, 78, 12)
    ]
    result = ground(payload(disclosures: [ field("CONTAINS SULFITES") ]), [ page(words) ])

    assert_equal [ 100, 500, 80, 28 ], result["disclosures"].first["bbox"]
    assert_equal "ocr", result["disclosures"].first["bbox_source"]
  end

  test "grounds varietals and disclosures arrays" do
    words = [ word("Chardonnay", 50, 200, 90, 14) ]
    result = ground(payload(varietals: [ field("Chardonnay") ]), [ page(words) ])

    assert_equal "ocr", result["varietals"].first["bbox_source"]
    assert_equal [ 50, 200, 90, 14 ], result["varietals"].first["bbox"]
  end

  test "uses the field's page and falls back to model when that page is missing" do
    page_two = page([ word("RESERVE", 40, 40, 70, 12) ], number: 2, width: 400, height: 500)
    fields = {
      "fanciful_name" => field("RESERVE", page: 2),
      "brand_name" => field("RESERVE", page: 3)
    }
    result = ground(payload(fields: fields), [ page_two ])

    assert_equal "ocr", result["fields"]["fanciful_name"]["bbox_source"]
    assert_equal [ 400, 500 ], result["fields"]["fanciful_name"]["bbox_basis"]
    assert_equal "model", result["fields"]["brand_name"]["bbox_source"]
  end

  test "passes through nil fields and empty text" do
    fields = { "appellation" => nil, "vintage" => field(nil) }
    result = ground(payload(fields: fields), [ page([ word("2021", 10, 10, 30, 10) ]) ])

    assert_nil result["fields"]["appellation"]
    assert_equal "model", result["fields"]["vintage"]["bbox_source"]
  end

  test "does not mutate the input payload" do
    input = payload(fields: { "brand_name" => field("OLD TOM") })
    frozen_snapshot = Marshal.load(Marshal.dump(input))
    ground(input, [ page([ word("OLD", 1, 2, 3, 4), word("TOM", 5, 2, 3, 4) ]) ])

    assert_equal frozen_snapshot, input
  end

  test "matches letter-spaced display type read as one word per letter" do
    letters = "DRAUGHT STOUT".delete(" ").chars.each_with_index.map do |letter, index|
      word(letter, 100 + index * 30, 400, 24, 30)
    end
    result = ground(payload(fields: { "fanciful_name" => field("DRAUGHT STOUT") }), [ page(letters) ])

    grounded = result["fields"]["fanciful_name"]
    assert_equal "ocr", grounded["bbox_source"]
    assert_equal [ 100, 400, 354, 30 ], grounded["bbox"]
  end

  test "grounds a long multi-line statement with a stray OCR error" do
    statement = "GOVERNMENT WARNING: (1) According to the Surgeon General, women should not drink alcoholic beverages during pregnancy"
    words = statement.split(" ").each_with_index.map do |token, index|
      printed = token == "risk" ? "tisk" : token
      word(printed, 20 + (index % 6) * 100, 700 + (index / 6) * 20, 90, 14)
    end
    fields = { "government_warning" => field(statement) }
    result = ground(payload(fields: fields), [ page(words) ])

    assert_equal "ocr", result["fields"]["government_warning"]["bbox_source"]
  end
end
