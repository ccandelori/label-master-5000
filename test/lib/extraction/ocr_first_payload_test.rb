# frozen_string_literal: true

require "test_helper"

class OcrFirstPayloadTest < ActiveSupport::TestCase
  STATUTORY = Rules::Data.statutory_warning_text

  def application(attrs)
    LabelApplication.create!({
      serial_number: "OCR-FIRST-1",
      beverage_type: "wine",
      brand_name: "BENCHMARK WINE",
      applicant_name_address: "Benchmark Winery, Napa, CA",
      alcohol_content: 13.5,
      net_contents: "750 mL",
      declared_class_type: "Red Wine",
      country_of_origin: nil,
      vintage_year: 2021,
      varietals: [ "Merlot" ],
      appellation: "Napa Valley"
    }.merge(attrs))
  end

  def word(text, x, y, width, height)
    Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: width, height: height)
  end

  def page(words)
    Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)
  end

  test "builds schema-shaped facts from OCR pages and application declarations" do
    app = application({})
    pages = [ page([
      word("BENCHMARK WINE", 100, 80, 260, 40),
      word("RED WINE", 100, 140, 120, 24),
      word("13.5% ALC/VOL", 100, 180, 150, 24),
      word("750 mL", 100, 220, 80, 24),
      word("PRODUCED BY BENCHMARK WINERY", 100, 260, 320, 24),
      word("NAPA CA", 100, 290, 100, 24),
      word("NAPA VALLEY", 100, 340, 140, 24),
      word("MERLOT", 100, 380, 80, 24),
      word("2021", 100, 420, 60, 24),
      word(STATUTORY, 100, 700, 560, 80),
      word("CONTAINS SULFITES", 100, 900, 170, 24)
    ]) ]

    payload = Extraction::OcrFirstPayload.build(application: app, pages: pages, threshold: 0.8)
    facts = Extraction::FactsMapper.to_facts(payload)
    checks = Rules::Engine.evaluate(application: app, facts: facts)

    assert_equal true, payload["legible"]
    assert_in_delta 0.75, payload["confidence"]
    assert_equal [ { "page" => 1, "width" => 800, "height" => 1000 } ], payload["pages"]
    assert_equal Extraction::Schema::FIELD_KEYS.sort, payload["fields"].keys.sort
    assert_equal "BENCHMARK WINE", facts.brand_name
    assert_equal "RED WINE", facts.class_type_designation
    assert_equal "13.5% ALC/VOL", facts.alcohol_statement
    assert_equal "750 mL", facts.net_contents
    assert_equal "PRODUCED BY BENCHMARK WINERY NAPA CA", facts.name_address_statement
    assert_equal "NAPA VALLEY", facts.appellation
    assert_equal 2021, facts.vintage_year
    assert_equal [ "MERLOT" ], facts.varietals
    assert_equal [ "CONTAINS SULFITES" ], facts.disclosures
    assert_equal STATUTORY, facts.government_warning_text
    assert_nil facts.warning_prefix_bold
    assert_nil facts.warning_continuous_paragraph
    assert_equal "ocr", payload.dig("fields", "brand_name", "bbox_source")
    assert_equal "ocr", payload.dig("fields", "government_warning", "bbox_source")
    assert checks.any? { |check| check.field == "brand_name" && check.verdict == "pass" }
    assert checks.any? { |check| check.field == "government_warning_text" && check.verdict == "pass" }
  end

  test "finds net contents from OCR when the application does not state a comparable value" do
    app = application({ serial_number: "OCR-FIRST-NET-SENTINEL", net_contents: ColaSampleIngest::NET_CONTENTS_SENTINEL })
    pages = [ page([
      word("BENCHMARK WINE", 100, 80, 260, 40),
      word("RED WINE", 100, 140, 120, 24),
      word("13.5% ALC/VOL", 100, 180, 150, 24),
      word("12 FL OZ (355 ML)", 100, 220, 180, 24)
    ]) ]

    payload = Extraction::OcrFirstPayload.build(application: app, pages: pages, threshold: 0.8)
    facts = Extraction::FactsMapper.to_facts(payload)

    assert_equal "12 FL OZ (355 ML)", facts.net_contents
  end

  test "finds visible class type from OCR when the application class is a broad registry category" do
    app = application({
      serial_number: "OCR-FIRST-CLASS-SWEEP",
      beverage_type: "malt",
      declared_class_type: "MALT BEVERAGES SPECIALITIES - FLAVORED",
      net_contents: "12 fl oz"
    })
    pages = [ page([
      word("BENCHMARK BREWING", 100, 80, 260, 40),
      word("HAZY INDIA PALE ALE", 100, 140, 220, 24),
      word("6.5% ALC/VOL", 100, 180, 150, 24),
      word("12 FL OZ", 100, 220, 100, 24)
    ]) ]

    payload = Extraction::OcrFirstPayload.build(application: app, pages: pages, threshold: 0.8)
    facts = Extraction::FactsMapper.to_facts(payload)

    assert_equal "HAZY INDIA PALE ALE", facts.class_type_designation
  end

  test "marks empty OCR as illegible with nil fields" do
    payload = Extraction::OcrFirstPayload.build(application: application({ serial_number: "OCR-FIRST-EMPTY" }),
                                               pages: [ page([]) ],
                                               threshold: 0.8)

    assert_equal false, payload["legible"]
    assert_in_delta 0.0, payload["confidence"]
    assert payload["fields"].values.all?(&:nil?)
    assert_empty payload["varietals"]
    assert_empty payload["disclosures"]
  end
end
