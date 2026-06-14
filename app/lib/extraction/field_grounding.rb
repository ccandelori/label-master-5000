# frozen_string_literal: true

require "bigdecimal"

module Extraction
  # Builds the application-specific search hints sent with a VLM extraction.
  # These values are targets, not evidence: the model must still return only
  # text it can see on the label, with the exact printed wording and location.
  module FieldGrounding
    Target = Data.define(:schema_path, :declared_value, :search_values, :instruction) do
      def as_json
        {
          "schema_path" => schema_path,
          "declared_value" => declared_value,
          "search_values" => search_values,
          "instruction" => instruction
        }
      end
    end

    BASE_INSTRUCTION = "Extract the label contents as schema-conforming JSON."
    ALCOHOL_SEARCH_SUFFIXES = [
      "%",
      "% ALC/VOL",
      "% ALC. BY VOL.",
      "% ALC./VOL.",
      "% ALCOHOL BY VOLUME",
      "% VOL"
    ].freeze

    module_function

    def prompt_text(application:)
      targets = targets_for(application: application)
      return BASE_INSTRUCTION if targets.empty?

      <<~TEXT
        #{BASE_INSTRUCTION}

        Application grounding targets are below. Use them only as search hints.
        For each target, search every label image and return the exact visible
        label text in the indicated schema slot when an equivalent printed value
        is present. Do not copy a declared value into the response unless that
        value, or an equivalent printed statement, is visible on the label.
        Preserve the full printed statement around the match and its bounding
        box. If no equivalent printed text is visible, leave that schema slot
        null rather than guessing.

        #{JSON.pretty_generate({ "application_search_targets" => targets.map(&:as_json) })}
        #{Extraction::RegulatoryEvidenceSchema.instruction_text(application: application)}
      TEXT
    end

    def targets_for(application:)
      return [] if application.nil?

      [
        scalar_target(
          schema_path: "fields.brand_name",
          value: application.brand_name,
          instruction: "Find the brand name declared on the application, not a nearby slogan or unrelated producer name."
        ),
        scalar_target(
          schema_path: "fields.fanciful_name",
          value: application.fanciful_name,
          instruction: "Find this distinctive product name only when it is printed as a product name, not as marketing copy."
        ),
        scalar_target(
          schema_path: "fields.class_type_designation",
          value: application.declared_class_type,
          instruction: "Find the beverage class/type designation or a printed equivalent such as White Wine for a declared table white wine."
        ),
        alcohol_target(application.alcohol_content),
        scalar_target(
          schema_path: "fields.net_contents",
          value: application.net_contents,
          instruction: "Find the net contents statement; match unit formatting flexibly, but return the exact printed text."
        ),
        scalar_target(
          schema_path: "fields.name_address_statement",
          value: application.applicant_name_address,
          instruction: "Find the bottler, importer, producer, brewer, or similar name/address statement corresponding to the application."
        ),
        scalar_target(
          schema_path: "fields.country_of_origin_statement",
          value: application.country_of_origin,
          instruction: "Find a country-of-origin statement containing this country, such as PRODUCT OF or PRODUCED IN wording."
        ),
        scalar_target(
          schema_path: "fields.appellation",
          value: application.appellation,
          instruction: "Find this wine appellation when it is printed as an origin/appellation statement."
        ),
        scalar_target(
          schema_path: "fields.vintage",
          value: application.vintage_year,
          instruction: "Find this vintage year only when it functions as the wine vintage, not when it is a serial number or unrelated code."
        ),
        varietal_target(application.varietals)
      ].flatten.compact
    end

    def scalar_target(schema_path:, value:, instruction:)
      declared = normalized_value(value)
      return nil if declared.empty?

      Target.new(
        schema_path: schema_path,
        declared_value: declared,
        search_values: text_variants(declared),
        instruction: instruction
      )
    end

    def alcohol_target(value)
      formatted = formatted_decimal(value)
      return nil if formatted.empty?

      Target.new(
        schema_path: "fields.alcohol_statement",
        declared_value: "#{formatted}% alcohol by volume",
        search_values: alcohol_variants(formatted),
        instruction: "Return the full printed alcohol-by-volume statement containing this ABV. Do not return a vintage year, net contents, serial number, or proof-only value as the alcohol statement."
      )
    end

    def varietal_target(values)
      varietals = Array(values).map { |value| normalized_value(value) }.reject(&:empty?)
      return nil if varietals.empty?

      Target.new(
        schema_path: "varietals[]",
        declared_value: varietals.join("; "),
        search_values: varietals.flat_map { |value| text_variants(value) }.uniq,
        instruction: "Find each declared grape variety when it is printed on the label; return each visible varietal as its own located entry."
      )
    end

    def text_variants(value)
      normalized = normalized_value(value)
      compact = normalized.delete(" ")
      [ normalized, normalized.upcase, compact, compact.upcase ].uniq
    end

    def alcohol_variants(formatted)
      alternate = formatted.include?(".") ? formatted.sub(/\.0+\z/, "") : "#{formatted}.0"
      numbers = [ formatted, alternate ].uniq
      numbers.flat_map do |number|
        ALCOHOL_SEARCH_SUFFIXES.map { |suffix| "#{number}#{suffix}" } +
          [ "ALC #{number}% BY VOL", "ALCOHOL #{number}% BY VOLUME" ]
      end.uniq
    end

    def normalized_value(value)
      value.to_s.strip
    end

    def formatted_decimal(value)
      return "" if value.nil?

      text = BigDecimal(value.to_s).to_s("F")
      text.sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
    end
  end
end
