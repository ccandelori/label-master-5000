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
    Extraction::FieldReconciler.reconcile_declared(
      payload: payload, pages: pages, field: "fanciful_name",
      expected: expected.to_s, threshold: THRESHOLD
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

  test "fills a missing statement from the line containing the applicant name" do
    input = { "fields" => { "name_address_statement" => nil } }
    lines = [
      word("STELLA ROSA", 10, 10, 200, 30),
      word("IMPORTED BY IL CONTE IMPORTS,", 20, 700, 400, 20),
      word("LOS ANGELES, CA", 20, 724, 150, 20)
    ]

    out = Extraction::FieldReconciler.reconcile_name_address(
      payload: input, pages: [ page(lines) ],
      expected: "IL CONTE IMPORTS, SAN ANTONIO WINERY, INC., 723 GIBBONS ST, LOS ANGELES, CA",
      threshold: 0.8
    )

    statement = out["fields"]["name_address_statement"]
    assert_equal "IMPORTED BY IL CONTE IMPORTS,", statement["text"]
    assert_equal "ocr", statement["bbox_source"]
    assert_equal [ 20, 700, 400, 20 ], statement["bbox"]
  end

  test "falls back to a statement-shaped line when the printed name differs" do
    input = { "fields" => { "name_address_statement" => nil } }
    lines = [
      word("GUINNESS DRAUGHT", 10, 10, 200, 30),
      word("IMPORTED BY DIAGEO BEER COMPANY USA,", 20, 700, 400, 20),
      word("NEW YORK, NY", 20, 724, 150, 20)
    ]

    out = Extraction::FieldReconciler.reconcile_name_address(
      payload: input, pages: [ page(lines) ],
      expected: "DIAGEO AMERICAS SUPPLY, INC., 3 WORLD TRADE CENTER, New York, NY",
      threshold: 0.8
    )

    statement = out["fields"]["name_address_statement"]
    assert_equal "IMPORTED BY DIAGEO BEER COMPANY USA, NEW YORK, NY", statement["text"]
    assert_equal [ 20, 700, 400, 44 ], statement["bbox"], "continuation line is carried"
  end

  test "a statement the model read is never second-guessed" do
    existing = { "text" => "BOTTLED BY SOMEONE", "bbox" => [ 1, 2, 3, 4 ], "page" => 1 }
    input = { "fields" => { "name_address_statement" => existing } }

    out = Extraction::FieldReconciler.reconcile_name_address(
      payload: input, pages: [ page([ word("IMPORTED BY OTHER CO", 1, 1, 9, 9) ]) ],
      expected: "OTHER CO, TOWN, CA", threshold: 0.8
    )

    assert_equal existing, out["fields"]["name_address_statement"]
  end

  test "no name match and no statement-shaped line leaves the payload alone" do
    input = { "fields" => { "name_address_statement" => nil } }

    out = Extraction::FieldReconciler.reconcile_name_address(
      payload: input, pages: [ page([ word("JUST A BRAND", 1, 1, 9, 9) ]) ],
      expected: "SOMEBODY ELSE, TOWN, CA", threshold: 0.8
    )

    assert_equal input, out
  end

  test "reconcile_declared replaces a field with the located declared value" do
    input = { "fields" => { "brand_name" => { "text" => "JOSH", "bbox" => [ 1, 2, 3, 4 ],
                                              "bbox_source" => "model", "page" => 1 } } }
    line = word("JOSH CELLARS RESERVE", 100, 50, 400, 60)

    out = Extraction::FieldReconciler.reconcile_declared(
      payload: input, pages: [ page([ line ]) ], field: "brand_name",
      expected: "JOSH CELLARS", threshold: 0.8
    )

    brand = out["fields"]["brand_name"]
    assert_equal "JOSH CELLARS", brand["text"]
    assert_equal "ocr", brand["bbox_source"]
    assert_equal [ 100, 50, 400, 60 ], brand["bbox"], "carries its parent line's box"
  end

  test "reconcile_statement_field carries the full statement line for a contained value" do
    input = { "fields" => {} }
    line = word("PRODUCT OF SCOTLAND", 50, 900, 300, 24)

    out = Extraction::FieldReconciler.reconcile_statement_field(
      payload: input, pages: [ page([ line ]) ], field: "country_of_origin_statement",
      expected: "Scotland", threshold: 0.8
    )

    statement = out["fields"]["country_of_origin_statement"]
    assert_equal "PRODUCT OF SCOTLAND", statement["text"]
    assert_equal [ 50, 900, 300, 24 ], statement["bbox"]
  end

  test "a replaced slot preserves the model's reading as model_text" do
    tagline = { "text" => "Lovely Day for a Guinness Limited Edition 2026",
                "bbox" => [ 1690, 1380, 560, 260 ], "page" => 1, "confidence" => 0.85 }
    words = [ word("DRAUGHT", 300, 500, 90, 30), word("STOUT", 400, 500, 70, 30) ]

    fanciful = reconcile(payload(tagline), [ page(words) ], "DRAUGHT STOUT")["fields"]["fanciful_name"]

    assert_equal "DRAUGHT STOUT", fanciful["text"]
    assert_equal "Lovely Day for a Guinness Limited Edition 2026", fanciful["model_text"]
  end

  test "re-reconciling a located slot carries model_text forward" do
    located = { "text" => "BROUWERU TIJ", "bbox" => [ 1, 2, 3, 4 ], "bbox_source" => "ocr",
                "bbox_basis" => [ 800, 1000 ], "page" => 1, "model_text" => "BROUWERIJ 'TIJ" }
    input = { "fields" => { "fanciful_name" => located } }
    words = [ word("BROUWERU", 10, 10, 90, 30), word("TIJ", 110, 10, 40, 30) ]

    out = Extraction::FieldReconciler.reconcile_declared(
      payload: input, pages: [ page(words) ], field: "fanciful_name",
      expected: "BROUWERIJ 'TIJ", threshold: 0.8
    )

    assert_equal "BROUWERIJ 'TIJ", out["fields"]["fanciful_name"]["model_text"]
  end

  test "no model_text when the slot was empty or reads the same" do
    words = [ word("DRAUGHT", 300, 500, 90, 30), word("STOUT", 400, 500, 70, 30) ]

    from_empty = reconcile(payload(nil), [ page(words) ], "DRAUGHT STOUT")
    assert_nil from_empty["fields"]["fanciful_name"]["model_text"]

    same = { "text" => "DRAUGHT STOUT", "bbox" => [ 1, 2, 3, 4 ], "page" => 1 }
    from_same = reconcile(payload(same), [ page(words) ], "DRAUGHT STOUT")
    assert_nil from_same["fields"]["fanciful_name"]["model_text"]
  end

  test "does not mutate its input" do
    input = payload(nil)
    snapshot = Marshal.load(Marshal.dump(input))
    reconcile(input, [ page([ word("DRAUGHT", 1, 1, 5, 5), word("STOUT", 7, 1, 5, 5) ]) ], "DRAUGHT STOUT")

    assert_equal snapshot, input
  end
end
