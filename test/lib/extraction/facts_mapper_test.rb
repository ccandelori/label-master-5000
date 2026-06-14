# frozen_string_literal: true

require "test_helper"

class FactsMapperTest < ActiveSupport::TestCase
  def located(text)
    { "text" => text, "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.9 }
  end

  test "texts_of keeps one entry per unique normalized text, preserving the first form" do
    fields = [
      located("CONTAINS SULFITES"),
      located("Contains Sulfites."),
      located("CONTAINS FD&C YELLOW #5")
    ]

    assert_equal [ "CONTAINS SULFITES", "CONTAINS FD&C YELLOW #5" ],
                 Extraction::FactsMapper.texts_of(fields)
  end

  test "texts_of drops nils and blank texts before deduplication" do
    fields = [ nil, located(""), located("  "), located("CONTAINS SULFITES") ]

    assert_equal [ "CONTAINS SULFITES" ], Extraction::FactsMapper.texts_of(fields)
  end

  test "to_facts deduplicates disclosures and varietals" do
    payload = {
      "fields" => {},
      "disclosures" => [ located("CONTAINS SULFITES"), located("contains sulfites") ],
      "varietals" => [ located("Chardonnay"), located("CHARDONNAY"), located("Viognier") ]
    }
    facts = Extraction::FactsMapper.to_facts(payload)

    assert_equal [ "CONTAINS SULFITES" ], facts.disclosures
    assert_equal [ "Chardonnay", "Viognier" ], facts.varietals
  end

  test "to_facts carries each reconciled field's model_text" do
    payload = {
      "fields" => {
        "brand_name" => { "text" => "BROUWERU TIJ", "model_text" => "BROUWERIJ 'TIJ" },
        "net_contents" => { "text" => "15 5 GALLONS", "model_text" => "15.5 GALLONS" },
        "fanciful_name" => { "text" => "DRAUGHT STOUT" }
      }
    }
    facts = Extraction::FactsMapper.to_facts(payload)

    assert_equal({ "brand_name" => "BROUWERIJ 'TIJ", "net_contents" => "15.5 GALLONS" },
                 facts.model_texts)
  end

  test "vintage_year falls back to model_text when located text carries no year" do
    payload = { "fields" => { "vintage" => { "text" => "2 0 2 1", "model_text" => "2021" } } }

    assert_equal 2021, Extraction::FactsMapper.to_facts(payload).vintage_year
  end

  test "to_facts maps each field's page into field_pages" do
    payload = {
      "fields" => {
        "brand_name" => { "text" => "ABC", "page" => 1 },
        "government_warning" => { "text" => "GOVERNMENT WARNING: ...", "page" => 2 },
        "net_contents" => { "text" => "750 mL" },
        "appellation" => nil
      }
    }
    facts = Extraction::FactsMapper.to_facts(payload)

    assert_equal({ "brand_name" => 1, "government_warning" => 2 }, facts.field_pages)
  end

  test "to_facts carries numeric field confidences" do
    payload = {
      "fields" => {
        "brand_name" => { "text" => "ABC", "confidence" => 0.96 },
        "fanciful_name" => { "text" => "Reserve", "confidence" => nil },
        "net_contents" => { "text" => "750 mL", "confidence" => "high" }
      }
    }

    assert_equal({ "brand_name" => 0.96 }, Extraction::FactsMapper.to_facts(payload).field_confidences)
  end

  test "to_facts carries each field source" do
    payload = {
      "fields" => {
        "brand_name" => { "text" => "ABC", "bbox_source" => "ocr" },
        "government_warning" => { "text" => "GOVERNMENT WARNING: ...", "bbox_source" => "model" },
        "fanciful_name" => { "text" => nil, "source" => "vlm_unsupported", "bbox_source" => "model" },
        "net_contents" => { "text" => "750 mL" },
        "appellation" => nil
      }
    }
    facts = Extraction::FactsMapper.to_facts(payload)

    assert_equal(
      { "brand_name" => "ocr", "government_warning" => "model", "fanciful_name" => "vlm_unsupported" },
      facts.field_sources
    )
  end
end
