# frozen_string_literal: true

module Extraction
  # Converts the richer regulatory_evidence object back into the legacy
  # extraction slots consumed by FactsMapper, Rules::Engine, and the review UI.
  module RegulatoryEvidenceMapper
    FIELD_KEYS = %w[
      brand_name fanciful_name class_type_designation alcohol_statement net_contents
      name_address_statement country_of_origin_statement government_warning
      commodity_statement appellation vintage
    ].freeze
    ARRAY_KEYS = {
      "varietals" => "varietals",
      "disclosures" => "disclosures"
    }.freeze
    PROMOTABLE_MATCH_STATUSES = %w[exact equivalent].freeze

    module_function

    def apply(payload)
      evidence = normalize_evidence(payload["regulatory_evidence"])
      return payload if evidence.nil?

      mapped = payload.deep_dup
      mapped["regulatory_evidence"] = evidence
      mapped["fields"] = mapped["fields"].is_a?(Hash) ? mapped["fields"] : {}
      map_field_evidence(mapped, evidence)
      map_array_evidence(mapped, evidence)
      mapped
    end

    def normalize_evidence(evidence)
      return evidence if evidence.is_a?(Hash)
      return nil unless evidence.is_a?(Array)

      evidence.each_with_object({}) do |entry, indexed|
        next unless entry.is_a?(Hash)

        key = entry["key"].to_s.strip
        next if key.empty?

        indexed[key] = entry.except("key")
      end
    end

    def map_field_evidence(mapped, evidence)
      FIELD_KEYS.each do |key|
        current = mapped["fields"][key]
        next if field_present?(current)
        next unless promotable_evidence?(key, evidence[key])

        slot = located_slot(evidence[key])
        next if slot.nil?

        mapped["fields"][key] = slot
      end
    end

    def map_array_evidence(mapped, evidence)
      ARRAY_KEYS.each do |evidence_key, payload_key|
        next unless promotable_evidence?(evidence_key, evidence[evidence_key])

        slot = located_slot(evidence[evidence_key])
        next if slot.nil?

        current = Array(mapped[payload_key])
        next if current.any? { |field| same_text?(field, slot) }

        mapped[payload_key] = current + [ slot ]
      end
    end

    def field_present?(field)
      field.is_a?(Hash) && !field["text"].to_s.strip.empty?
    end

    def promotable_evidence?(key, evidence)
      return false unless evidence.is_a?(Hash)
      return false unless PROMOTABLE_MATCH_STATUSES.include?(evidence["match_status"].to_s)
      return false unless evidence["visible"] == true
      return false if evidence["verbatim_text"].to_s.strip.empty?
      return true unless key == "government_warning"

      statutory_warning_text?(evidence["verbatim_text"])
    end

    def statutory_warning_text?(text)
      Parsing::WarningComparator.compare(text, Rules::Data.statutory_warning_text).text_matches
    end

    def located_slot(evidence)
      return nil unless evidence.is_a?(Hash)
      return nil unless evidence["visible"] == true

      text = evidence["verbatim_text"].to_s.strip
      return nil if text.empty?

      {
        "text" => text,
        "source" => "model",
        "page" => evidence["page"],
        "confidence" => evidence["confidence"],
        "declared_value" => evidence["declared_value"],
        "evidence_match_status" => evidence["match_status"],
        "evidence_note" => evidence["evidence_note"]
      }
    end

    def same_text?(field, slot)
      return false unless field.is_a?(Hash)

      Parsing::TextNormalizer.equivalent?(field["text"], slot["text"])
    end
  end
end
