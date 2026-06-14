# frozen_string_literal: true

require "test_helper"

class RegulatoryEvidenceMapperTest < ActiveSupport::TestCase
  def evidence(text:, status:, visible: true, bbox: [ 10, 20, 100, 24 ])
    {
      "declared_value" => "13.5% alcohol by volume",
      "visible" => visible,
      "match_status" => status,
      "verbatim_text" => text,
      "bbox" => bbox,
      "page" => 2,
      "confidence" => 0.93,
      "evidence_note" => "Found on the back label"
    }
  end

  test "visible regulatory evidence populates the legacy field slot" do
    payload = {
      "fields" => { "alcohol_statement" => nil },
      "regulatory_evidence" => {
        "alcohol_statement" => evidence(text: "13.5% ALC/VOL", status: "equivalent")
      }
    }

    mapped = Extraction::RegulatoryEvidenceMapper.apply(payload)
    field = mapped.dig("fields", "alcohol_statement")

    assert_equal "13.5% ALC/VOL", field["text"]
    assert_nil field["bbox"]
    assert_nil field["bbox_source"]
    assert_equal "model", field["source"]
    assert_equal "equivalent", field["evidence_match_status"]
    assert_equal "Found on the back label", field["evidence_note"]
    assert_nil payload.dig("fields", "alcohol_statement"), "mapper must not mutate input"
  end

  test "regulatory evidence does not overwrite an existing field read" do
    payload = {
      "fields" => {
        "government_warning" => {
          "text" => "GOVERNMENT WARNING: Correct base read",
          "bbox" => [ 1, 2, 3, 4 ],
          "page" => 1,
          "confidence" => 0.8
        }
      },
      "regulatory_evidence" => {
        "government_warning" => evidence(
          text: "GOVERNMENT WARNING: Hallucinated different read",
          status: "conflict"
        )
      }
    }

    mapped = Extraction::RegulatoryEvidenceMapper.apply(payload)

    assert_equal "GOVERNMENT WARNING: Correct base read", mapped.dig("fields", "government_warning", "text")
    assert_equal "GOVERNMENT WARNING: Hallucinated different read",
                 mapped.dig("regulatory_evidence", "government_warning", "verbatim_text")
  end

  test "non-statutory government warning evidence does not fill canonical warning field" do
    payload = {
      "fields" => { "government_warning" => nil },
      "regulatory_evidence" => {
        "government_warning" => evidence(
          text: "GOVERNMENT WARNING (1) ACCORDING TO THE SURGEON GENERAL THIS PRODUCT (3) ALCOHOL ABUSE",
          status: "conflict"
        )
      }
    }

    mapped = Extraction::RegulatoryEvidenceMapper.apply(payload)

    assert_nil mapped.dig("fields", "government_warning")
    assert_equal "GOVERNMENT WARNING (1) ACCORDING TO THE SURGEON GENERAL THIS PRODUCT (3) ALCOHOL ABUSE",
                 mapped.dig("regulatory_evidence", "government_warning", "verbatim_text")
  end

  test "missing evidence does not fabricate field text" do
    payload = {
      "fields" => { "alcohol_statement" => nil },
      "regulatory_evidence" => {
        "alcohol_statement" => evidence(text: nil, status: "missing", visible: false, bbox: nil)
      }
    }

    mapped = Extraction::RegulatoryEvidenceMapper.apply(payload)

    assert_nil mapped.dig("fields", "alcohol_statement")
  end

  test "varietal regulatory evidence appends to varietals" do
    payload = {
      "fields" => {},
      "varietals" => [],
      "regulatory_evidence" => {
        "varietals" => evidence(text: "Riesling", status: "exact")
      }
    }

    mapped = Extraction::RegulatoryEvidenceMapper.apply(payload)
    varietal = mapped["varietals"].first

    assert_equal "Riesling", varietal["text"]
    assert_equal "exact", varietal["evidence_match_status"]
  end

  test "array regulatory evidence from compact providers maps by key" do
    payload = {
      "fields" => { "alcohol_statement" => nil },
      "regulatory_evidence" => [
        evidence(text: "42% ALC/VOL", status: "exact").merge("key" => "alcohol_statement")
      ]
    }

    mapped = Extraction::RegulatoryEvidenceMapper.apply(payload)

    assert_equal "42% ALC/VOL", mapped.dig("fields", "alcohol_statement", "text")
    assert_kind_of Hash, mapped["regulatory_evidence"]
    assert_equal "42% ALC/VOL", mapped.dig("regulatory_evidence", "alcohol_statement", "verbatim_text")
  end
end
