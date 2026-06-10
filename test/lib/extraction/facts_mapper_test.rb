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
end
