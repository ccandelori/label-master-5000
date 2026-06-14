# frozen_string_literal: true

require "bigdecimal"

module Extraction
  # Application-specific structured-output schema for COLA evidence. The model
  # still reads the label artwork, but every regulatory field gets an explicit
  # evidence slot with declared values, confusion warnings, and match status.
  module RegulatoryEvidenceSchema
    Definition = Data.define(:key, :declared_value, :required, :instruction, :forbidden_confusions)

    MATCH_STATUSES = %w[exact equivalent conflict missing uncertain not_applicable].freeze

    NULLABLE_EVIDENCE_FIELD_SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "properties" => {
        "declared_value" => { "type" => %w[string null] },
        "visible" => { "type" => "boolean" },
        "match_status" => {
          "type" => "string",
          "enum" => MATCH_STATUSES
        },
        "verbatim_text" => { "type" => %w[string null] },
        "page" => { "type" => %w[integer null] },
        "confidence" => { "type" => %w[number null] },
        "evidence_note" => { "type" => %w[string null] }
      },
      "required" => %w[declared_value visible match_status verbatim_text page confidence evidence_note]
    }.freeze

    COMPACT_EVIDENCE_FIELD_SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "properties" => {
        "declared_value" => {
          "type" => "string",
          "description" => "Application value for this field, or an empty string when not declared"
        },
        "visible" => { "type" => "boolean" },
        "match_status" => {
          "type" => "string",
          "enum" => MATCH_STATUSES
        },
        "verbatim_text" => {
          "type" => "string",
          "description" => "Exact visible label text, or an empty string when no evidence is visible"
        },
        "page" => {
          "type" => "integer",
          "description" => "1-based image page when visible; otherwise 0"
        },
        "confidence" => {
          "type" => "number",
          "description" => "0 to 1 confidence when visible; otherwise 0"
        },
        "evidence_note" => {
          "type" => "string",
          "description" => "Short note explaining the evidence or why it is missing"
        }
      },
      "required" => %w[declared_value visible match_status verbatim_text page confidence evidence_note]
    }.freeze

    module_function

    def response_schema(application:)
      return Schema::RESPONSE_SCHEMA if application.nil?

      definitions = definitions_for(application: application)
      schema = Schema::RESPONSE_SCHEMA.deep_dup
      schema["properties"]["regulatory_evidence"] =
        evidence_object_schema(definitions, NULLABLE_EVIDENCE_FIELD_SCHEMA)
      schema["required"] = (schema["required"] + [ "regulatory_evidence" ]).uniq
      schema
    end

    def anthropic_response_schema(application:)
      return Schema::RESPONSE_SCHEMA if application.nil?

      definitions = definitions_for(application: application)
      schema = Schema::RESPONSE_SCHEMA.deep_dup
      schema["properties"]["regulatory_evidence"] = evidence_array_schema(definitions)
      schema["required"] = (schema["required"] + [ "regulatory_evidence" ]).uniq
      schema
    end

    def instruction_text(application:)
      definitions = definitions_for(application: application)
      return "" if definitions.empty?

      <<~TEXT

        Also fill regulatory_evidence. Treat it as field-by-field COLA evidence,
        not as a legal verdict. For every regulatory_evidence key, search all
        label images and return only visible label evidence:
        - match_status exact/equivalent when the visible label text satisfies the declared value.
        - match_status conflict when a different visible value is printed.
        - match_status missing when no visible evidence is found.
        - match_status uncertain when glare, blur, stylization, or cropping prevents a reliable read.
        - When the response schema does not allow null, use empty strings, an
          page 0, and confidence 0 for missing evidence.

        #{JSON.pretty_generate({ "regulatory_evidence_fields" => definitions.map { |definition| definition_payload(definition) } })}
      TEXT
    end

    def definitions_for(application:)
      return [] if application.nil?

      fields = [
        definition(
          key: "brand_name",
          declared_value: application.brand_name,
          required: true,
          instruction: "Find the brand name required for COLA identity review. Prefer the declared product brand over slogans, importer names, producer names, or vineyard/location names.",
          forbidden_confusions: [ "slogan", "producer name", "importer name", "appellation", "serial number" ]
        ),
        definition(
          key: "class_type_designation",
          declared_value: application.declared_class_type,
          required: true,
          instruction: "Find the class/type designation or statement of identity for the beverage category.",
          forbidden_confusions: [ "fanciful name", "brand name", "vintage year", "net contents" ]
        ),
        alcohol_definition(application),
        definition(
          key: "net_contents",
          declared_value: application.net_contents,
          required: true,
          instruction: "Find the net contents statement, including unit words or abbreviations exactly as printed.",
          forbidden_confusions: [ "alcohol percentage", "vintage year", "bottle deposit", "serial number" ]
        ),
        definition(
          key: "name_address_statement",
          declared_value: application.applicant_name_address,
          required: true,
          instruction: "Find the complete bottler, importer, producer, brewer, packed-by, manufactured-by, or similar name/address statement.",
          forbidden_confusions: [ "brand name", "web address", "government warning", "country of origin alone" ]
        ),
        definition(
          key: "government_warning",
          declared_value: "GOVERNMENT WARNING",
          required: true,
          instruction: "Find the complete government health warning block, including the GOVERNMENT WARNING prefix and all warning text.",
          forbidden_confusions: [ "responsibility slogan", "disclosure statement", "allergen statement" ]
        ),
        definition(
          key: "disclosures",
          declared_value: nil,
          required: false,
          instruction: "Find standalone mandatory disclosure statements such as CONTAINS SULFITES or ingredient/color additive disclosures.",
          forbidden_confusions: [ "marketing copy", "bottle deposit", "serving suggestion" ]
        )
      ].compact

      fields << definition(
        key: "fanciful_name",
        declared_value: application.fanciful_name,
        required: false,
        instruction: "Find the declared fanciful name only when printed as a product name.",
        forbidden_confusions: [ "slogan", "seasonal phrase", "appellation", "class/type designation" ]
      ) if application.fanciful_name.present?

      fields << definition(
        key: "country_of_origin_statement",
        declared_value: application.country_of_origin,
        required: application.imported?,
        instruction: "Find the country-of-origin statement, usually PRODUCT OF, PRODUCED IN, IMPORTED FROM, or similar wording.",
        forbidden_confusions: [ "importer address", "appellation", "brand geography" ]
      ) if application.imported? || application.country_of_origin.present?

      wine_definitions(application).each { |field| fields << field } if application.wine?
      spirits_definitions(application).each { |field| fields << field } if application.spirits?
      fields
    end

    def wine_definitions(application)
      [
        definition(
          key: "varietals",
          declared_value: Array(application.varietals).join("; "),
          required: false,
          instruction: "Find each grape variety declared or visibly printed on the wine label.",
          forbidden_confusions: [ "appellation", "brand name", "fanciful name", "quality statement" ]
        ),
        definition(
          key: "appellation",
          declared_value: application.appellation,
          required: false,
          instruction: "Find the wine appellation or appellation of origin when printed.",
          forbidden_confusions: [ "country of origin", "producer address", "brand name" ]
        ),
        definition(
          key: "vintage",
          declared_value: application.vintage_year,
          required: false,
          instruction: "Find the wine vintage year only when it functions as a vintage.",
          forbidden_confusions: [ "serial number", "approval year", "copyright year", "lot code" ]
        )
      ].compact
    end

    def spirits_definitions(_application)
      [
        definition(
          key: "commodity_statement",
          declared_value: nil,
          required: false,
          instruction: "Find any commodity statement required for the spirits identity, such as neutral spirits source statements.",
          forbidden_confusions: [ "class/type designation", "government warning", "marketing copy" ]
        )
      ]
    end

    def alcohol_definition(application)
      return nil if application.alcohol_content.nil? && application.malt?

      declared = application.alcohol_content.nil? ? nil : "#{decimal(application.alcohol_content)}% alcohol by volume"
      definition(
        key: "alcohol_statement",
        declared_value: declared,
        required: !application.malt?,
        instruction: "Find the full alcohol-by-volume statement as printed, including ALC/VOL wording and any proof text when present.",
        forbidden_confusions: [ "proof-only value", "vintage year", "net contents", "serial number", "bottle deposit" ]
      )
    end

    def definition(key:, declared_value:, required:, instruction:, forbidden_confusions:)
      Definition.new(
        key: key,
        declared_value: declared_value.to_s.strip.presence,
        required: required,
        instruction: instruction,
        forbidden_confusions: forbidden_confusions
      )
    end

    def evidence_object_schema(definitions, field_schema)
      {
        "type" => "object",
        "additionalProperties" => false,
        "properties" => definitions.to_h { |definition| [ definition.key, evidence_field_schema(definition, field_schema) ] },
        "required" => definitions.map(&:key)
      }
    end

    def evidence_array_schema(definitions)
      keys = definitions.map(&:key)
      field_schema = COMPACT_EVIDENCE_FIELD_SCHEMA.deep_dup
      field_schema["properties"] = field_schema["properties"].merge(
        "key" => {
          "type" => "string",
          "enum" => keys,
          "description" => "Regulatory evidence key"
        }
      )
      field_schema["required"] = [ "key" ] + field_schema["required"]
      {
        "type" => "array",
        "items" => field_schema,
        "description" => "One evidence item for each key: #{keys.join(', ')}"
      }
    end

    def evidence_field_schema(definition, field_schema)
      field_schema.deep_dup.merge("description" => description_for(definition))
    end

    def description_for(definition)
      parts = [
        definition.instruction,
        "Declared/application value: #{definition.declared_value || 'not declared'}",
        "Requiredness hint for this application: #{definition.required ? 'required or expected' : 'conditional or optional'}"
      ]
      if definition.forbidden_confusions.any?
        parts << "Do not confuse with: #{definition.forbidden_confusions.join(', ')}."
      end
      parts.join(" ")
    end

    def definition_payload(definition)
      {
        "key" => definition.key,
        "declared_value" => definition.declared_value,
        "required_hint" => definition.required,
        "instruction" => definition.instruction,
        "do_not_confuse_with" => definition.forbidden_confusions
      }
    end

    def decimal(value)
      BigDecimal(value.to_s).to_s("F").sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
    end
  end
end
