# frozen_string_literal: true

require "test_helper"

class FieldReconcilerTest < ActiveSupport::TestCase
  THRESHOLD = 0.8

  def word(text, x, y, width, height)
    Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: width, height: height)
  end

  def page(words, number: 1)
    Extraction::OcrClient::Page.new(number: number, width: 800, height: 1000, words: words)
  end

  def payload(fanciful)
    {
      "fields" => { "fanciful_name" => fanciful, "brand_name" => { "text" => "GUINNESS" } },
      "disclosures" => []
    }
  end

  def reconcile(payload, pages, expected)
    Extraction::FieldReconciler.reconcile_fanciful_name(
      payload: payload, pages: pages, expected: expected, threshold: THRESHOLD
    )
  end

  test "replaces a tagline misread with the declared name located by OCR" do
    tagline = { "text" => "Lovely Day for a Guinness Limited Edition 2026",
                "bbox" => [ 1690, 1380, 560, 260 ], "page" => 1, "confidence" => 0.85 }
    words = [ word("DRAUGHT", 300, 500, 90, 30), word("STOUT", 400, 500, 70, 30) ]

    result = reconcile(payload(tagline), [ page(words) ], "DRAUGHT STOUT")
    fanciful = result["fields"]["fanciful_name"]

    assert_equal "DRAUGHT STOUT", fanciful["text"]
    assert_equal [ 300, 500, 170, 30 ], fanciful["bbox"]
    assert_equal [ 800, 1000 ], fanciful["bbox_basis"]
    assert_equal "ocr", fanciful["bbox_source"]
    assert_equal 1, fanciful["page"]
  end

  test "fills an empty slot when the declared name is printed but the model missed it" do
    words = [ word("Draught", 300, 500, 90, 30), word("Stout", 400, 500, 70, 30) ]
    result = reconcile(payload(nil), [ page(words) ], "DRAUGHT STOUT")

    assert_equal "Draught Stout", result["fields"]["fanciful_name"]["text"]
  end

  test "leaves the payload alone when OCR cannot locate the declared name" do
    tagline = { "text" => "Lovely Day", "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.85 }
    words = [ word("UNRELATED", 10, 10, 50, 10) ]
    input = payload(tagline)

    assert_equal input, reconcile(input, [ page(words) ], "DRAUGHT STOUT")
  end

  test "no declared fanciful name is a no-op" do
    input = payload({ "text" => "Lovely Day", "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.85 })

    assert_equal input, reconcile(input, [ page([ word("DRAUGHT", 1, 1, 5, 5) ]) ], nil)
    assert_equal input, reconcile(input, [ page([ word("DRAUGHT", 1, 1, 5, 5) ]) ], "  ")
  end

  test "searches later pages and records the page number" do
    front = page([ word("GUINNESS", 10, 10, 80, 20) ], number: 1)
    back = page([ word("DRAUGHT", 300, 500, 90, 30), word("STOUT", 400, 500, 70, 30) ], number: 2)

    result = reconcile(payload(nil), [ front, back ], "DRAUGHT STOUT")

    assert_equal 2, result["fields"]["fanciful_name"]["page"]
  end

  test "does not mutate its input" do
    input = payload(nil)
    snapshot = Marshal.load(Marshal.dump(input))
    reconcile(input, [ page([ word("DRAUGHT", 1, 1, 5, 5), word("STOUT", 7, 1, 5, 5) ]) ], "DRAUGHT STOUT")

    assert_equal snapshot, input
  end
end
