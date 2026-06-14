# frozen_string_literal: true

require "test_helper"

class VlmReconcilerTest < ActiveSupport::TestCase
  def application(attributes)
    LabelApplication.new({
      brand_name: "MIA-LOU",
      applicant_name_address: "Credo Properties LLC, Mechanicsburg, PA",
      net_contents: "750 mL"
    }.merge(attributes))
  end

  def field(text, bbox)
    { "text" => text, "bbox" => bbox, "page" => 1, "confidence" => 0.91 }
  end

  def raw_word(text, x, y, width: 100, height: 20, confidence: 0.9)
    Extraction::OcrClient.build_word(
      text: text,
      x: x,
      y: y,
      width: width,
      height: height,
      confidence: confidence
    )
  end

  def evidence(words)
    raw_page = Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)
    page = Extraction::OcrEvidenceStore.normalize_page(raw_page)
    Extraction::OcrEvidenceStore::Evidence.new(pages: [ page ], engine_key: "test")
  end

  test "moves a matching ABV candidate into the alcohol statement slot" do
    payload = {
      "fields" => {
        "alcohol_statement" => nil,
        "vintage" => field("2022", [ 1, 2, 30, 20 ]),
        "commodity_statement" => field("13.5% ALC/VOL", [ 10, 20, 120, 24 ])
      },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.reconcile(
      payload: payload,
      application: application(alcohol_content: 13.5)
    )

    alcohol = result.dig("fields", "alcohol_statement")
    assert_equal "13.5% ALC/VOL", alcohol["text"]
    assert_equal [ 10, 20, 120, 24 ], alcohol["bbox"]
    assert_equal "model", alcohol["bbox_source"]
    assert_equal "vlm_reconciled", alcohol["source"]
    assert_nil payload.dig("fields", "alcohol_statement"), "reconciliation must not mutate the original payload"
  end

  test "does not treat vintage or proof-only text as a matching ABV" do
    payload = {
      "fields" => {
        "alcohol_statement" => nil,
        "vintage" => field("2022", [ 1, 2, 30, 20 ]),
        "commodity_statement" => field("80 PROOF", [ 10, 20, 120, 24 ])
      },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.reconcile(
      payload: payload,
      application: application(alcohol_content: 40.0)
    )

    assert_nil result.dig("fields", "alcohol_statement")
  end

  test "corrects a text field when the VLM put the declared value in another slot" do
    payload = {
      "fields" => {
        "brand_name" => field("MARTINISTHALER RÖDCHEN", [ 1, 2, 300, 30 ]),
        "fanciful_name" => field("Mia-Lou", [ 10, 20, 120, 24 ])
      },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.reconcile(
      payload: payload,
      application: application(brand_name: "MIA-LOU")
    )

    brand = result.dig("fields", "brand_name")
    assert_equal "Mia-Lou", brand["text"]
    assert_equal [ 10, 20, 120, 24 ], brand["bbox"]
    assert_equal "vlm_reconciled", brand["source"]
  end

  test "does not promote arbitrary matching years into the vintage slot" do
    payload = {
      "fields" => {
        "vintage" => nil,
        "brand_name" => field("2022", [ 1, 2, 60, 20 ])
      },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.reconcile(
      payload: payload,
      application: application(vintage_year: 2022)
    )

    assert_nil result.dig("fields", "vintage")
  end

  test "grounds VLM text when OCR evidence supports it" do
    payload = {
      "fields" => { "brand_name" => field("MIA LOU", [ 400, 400, 120, 30 ]) },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.ground(
      payload: payload,
      evidence: evidence([ raw_word("Mia-Lou", 10, 20, width: 90) ]),
      threshold: 0.75
    )

    brand = result.dig("fields", "brand_name")
    assert_equal "Mia-Lou", brand["text"]
    assert_equal [ 10, 20, 90, 20 ], brand["bbox"]
    assert_equal [ 800, 1000 ], brand["bbox_basis"]
    assert_equal "ocr", brand["bbox_source"]
    assert_equal "ocr_grounded", brand["source"]
    assert_nil payload.dig("fields", "brand_name", "bbox_basis"), "grounding must not mutate the original payload"
  end

  test "rejects VLM text with no OCR support and no valid region" do
    payload = {
      "fields" => { "fanciful_name" => field("HALLUCINATED RESERVE", nil) },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.ground(
      payload: payload,
      evidence: evidence([ raw_word("MIA-LOU", 10, 20) ]),
      threshold: 0.75
    )

    fanciful = result.dig("fields", "fanciful_name")
    assert_nil fanciful["text"]
    assert_equal "ambiguous", fanciful["confidence"]
    assert_equal "vlm_unsupported", fanciful["source"]
    assert_equal "HALLUCINATED RESERVE", fanciful["model_text"]
  end

  test "keeps a valid VLM region only as ambiguous evidence when OCR misses the text" do
    payload = {
      "fields" => { "brand_name" => field("MIA-LOU", [ 10, 20, 90, 20 ]) },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.ground(
      payload: payload,
      evidence: evidence([]),
      threshold: 0.75
    )

    brand = result.dig("fields", "brand_name")
    assert_nil brand["text"]
    assert_equal [ 10, 20, 90, 20 ], brand["bbox"]
    assert_equal "model", brand["bbox_source"]
    assert_equal "vlm_region", brand["source"]
    assert_equal "ambiguous", brand["confidence"]
    assert_equal "MIA-LOU", brand["model_text"]
  end

  test "grounds alcohol statement by parsed OCR value" do
    payload = {
      "fields" => { "alcohol_statement" => field("4.5%", [ 300, 400, 80, 20 ]) },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.ground(
      payload: payload,
      evidence: evidence([ raw_word("4.5% ALC/VOL", 10, 20, width: 140) ]),
      threshold: 0.75
    )

    alcohol = result.dig("fields", "alcohol_statement")
    assert_equal "4.5% ALC/VOL", alcohol["text"]
    assert_equal "ocr_grounded", alcohol["source"]
  end

  test "rejects government warning text when OCR overlap is too weak" do
    payload = {
      "fields" => {
        "government_warning" => field("GOVERNMENT WARNING: alcohol abuse alcohol abuse", nil)
      },
      "varietals" => [],
      "disclosures" => []
    }

    result = Extraction::VlmReconciler.ground(
      payload: payload,
      evidence: evidence([ raw_word("GOVERNMENT WARNING", 10, 20, width: 180) ]),
      threshold: 0.75
    )

    warning = result.dig("fields", "government_warning")
    assert_nil warning["text"]
    assert_equal "vlm_unsupported", warning["source"]
    assert_equal "GOVERNMENT WARNING: alcohol abuse alcohol abuse", warning["model_text"]
  end
end
