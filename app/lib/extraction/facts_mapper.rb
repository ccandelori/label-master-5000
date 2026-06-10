# frozen_string_literal: true

module Extraction
  # Maps the raw extraction payload (the model's JSON, bounding boxes and
  # all) to the LabelFacts the rules engine consumes. Pure and total: any
  # missing structure maps to nil/empty rather than raising.
  module FactsMapper
    module_function

    def to_facts(payload)
      fields = payload["fields"] || {}
      warning = payload["warning_attributes"] || {}

      LabelFacts.new(
        brand_name: text_of(fields["brand_name"]),
        fanciful_name: text_of(fields["fanciful_name"]),
        class_type_designation: text_of(fields["class_type_designation"]),
        alcohol_statement: text_of(fields["alcohol_statement"]),
        net_contents: text_of(fields["net_contents"]),
        name_address_statement: text_of(fields["name_address_statement"]),
        country_of_origin_statement: text_of(fields["country_of_origin_statement"]),
        government_warning_text: text_of(fields["government_warning"]),
        warning_prefix_bold: warning["prefix_bold"],
        warning_continuous_paragraph: warning["continuous_paragraph"],
        disclosures: texts_of(payload["disclosures"]),
        varietals: texts_of(payload["varietals"]),
        appellation: text_of(fields["appellation"]),
        vintage_year: vintage_year(fields["vintage"]),
        commodity_statement: text_of(fields["commodity_statement"]),
        legible: payload.fetch("legible", true),
        confidence: payload["confidence"]
      )
    end

    def text_of(field)
      return nil if field.nil?

      text = field["text"]
      text.to_s.strip.empty? ? nil : text.strip
    end

    # The model reports one entry per printed occurrence, so a statement
    # repeated on the label (front and back panel, say) arrives twice;
    # the rules care about what is declared, not how many times.
    def texts_of(fields)
      Array(fields).filter_map { |f| text_of(f) }
                   .uniq { |text| Parsing::TextNormalizer.normalize(text) }
    end

    def vintage_year(field)
      text = text_of(field)
      return nil if text.nil?

      match = text[/\b(1[89]\d{2}|20\d{2})\b/, 1]
      match&.to_i
    end
  end
end
