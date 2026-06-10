# frozen_string_literal: true

module Extraction
  # The contract between the vision extractor (producer) and the rules
  # engine (consumer). Field values are the literal text read from the
  # label, nil when absent. Visual attributes are true/false when the
  # extractor could assess them and nil when it could not.
  LabelFacts = Data.define(
    :brand_name,
    :fanciful_name,
    :class_type_designation,
    :alcohol_statement,
    :net_contents,
    :name_address_statement,
    :country_of_origin_statement,
    :government_warning_text,
    :warning_prefix_bold,
    :warning_continuous_paragraph,
    :disclosures,
    :varietals,
    :appellation,
    :vintage_year,
    :commodity_statement,
    :legible,
    :confidence
  ) do
    def self.from_h(hash)
      h = hash.transform_keys(&:to_s)
      new(
        brand_name: h.fetch("brand_name", nil),
        fanciful_name: h.fetch("fanciful_name", nil),
        class_type_designation: h.fetch("class_type_designation", nil),
        alcohol_statement: h.fetch("alcohol_statement", nil),
        net_contents: h.fetch("net_contents", nil),
        name_address_statement: h.fetch("name_address_statement", nil),
        country_of_origin_statement: h.fetch("country_of_origin_statement", nil),
        government_warning_text: h.fetch("government_warning_text", nil),
        warning_prefix_bold: h.fetch("warning_prefix_bold", nil),
        warning_continuous_paragraph: h.fetch("warning_continuous_paragraph", nil),
        disclosures: Array(h.fetch("disclosures", [])),
        varietals: Array(h.fetch("varietals", [])),
        appellation: h.fetch("appellation", nil),
        vintage_year: h.fetch("vintage_year", nil),
        commodity_statement: h.fetch("commodity_statement", nil),
        legible: h.fetch("legible", true),
        confidence: h.fetch("confidence", nil)
      )
    end
  end
end
