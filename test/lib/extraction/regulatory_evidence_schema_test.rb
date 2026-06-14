# frozen_string_literal: true

require "test_helper"

class RegulatoryEvidenceSchemaTest < ActiveSupport::TestCase
  test "nil application uses the legacy extraction schema" do
    assert_same Extraction::Schema::RESPONSE_SCHEMA,
                Extraction::RegulatoryEvidenceSchema.response_schema(application: nil)
  end

  test "wine application schema includes declared COLA evidence fields" do
    application = LabelApplication.new(
      beverage_type: "wine",
      brand_name: "MIA-LOU",
      fanciful_name: "Roter Riesling feinherb",
      declared_class_type: "TABLE WHITE WINE",
      alcohol_content: 13.5,
      net_contents: "750 mL",
      applicant_name_address: "Credo Properties LLC, Mechanicsburg, PA",
      country_of_origin: "Germany",
      imported: true,
      varietals: [ "Riesling" ],
      appellation: "Rheingau",
      vintage_year: 2022
    )

    schema = Extraction::RegulatoryEvidenceSchema.response_schema(application: application)
    evidence = schema.dig("properties", "regulatory_evidence")

    assert_includes schema["required"], "regulatory_evidence"
    assert_includes evidence["required"], "alcohol_statement"
    assert_includes evidence["required"], "class_type_designation"
    assert_includes evidence["required"], "varietals"
    assert_includes evidence["required"], "country_of_origin_statement"
    assert_match(/13\.5% alcohol by volume/, evidence.dig("properties", "alcohol_statement", "description"))
    assert_match(/proof-only/, evidence.dig("properties", "alcohol_statement", "description"))
    assert_match(/Riesling/, evidence.dig("properties", "varietals", "description"))
  end

  test "anthropic schema keeps regulatory evidence without exceeding union limit" do
    application = LabelApplication.new(
      beverage_type: "spirits",
      brand_name: "STELLA ROSA",
      fanciful_name: "V.S.",
      declared_class_type: "Brandy",
      alcohol_content: 42.0,
      net_contents: "750 ML",
      applicant_name_address: "IL CONTE IMPORTS, SAN ANTONIO WINERY, INC., LOS ANGELES, CA",
      country_of_origin: "Spain",
      imported: true
    )

    schema = Extraction::RegulatoryEvidenceSchema.anthropic_response_schema(application: application)
    evidence = schema.dig("properties", "regulatory_evidence")

    assert_includes schema["required"], "regulatory_evidence"
    assert_equal "array", evidence["type"]
    assert_includes evidence.dig("items", "properties", "key", "enum"), "alcohol_statement"
    assert_operator union_schema_count(schema), :<=, 16
    assert_equal "string", evidence.dig("items", "properties", "verbatim_text", "type")
    assert_nil evidence.dig("items", "properties", "bbox")
    assert_not_includes evidence.dig("items", "required"), "bbox"
  end

  test "openai regulatory evidence schema does not ask the VLM for boxes" do
    application = LabelApplication.new(
      beverage_type: "spirits",
      brand_name: "STELLA ROSA",
      declared_class_type: "Brandy",
      alcohol_content: 42.0,
      net_contents: "750 ML",
      applicant_name_address: "IL CONTE IMPORTS, LOS ANGELES, CA"
    )

    schema = Extraction::RegulatoryEvidenceSchema.response_schema(application: application)
    alcohol = schema.dig("properties", "regulatory_evidence", "properties", "alcohol_statement")

    assert_nil alcohol.dig("properties", "bbox")
    assert_not_includes alcohol["required"], "bbox"
  end

  test "malt application schema omits wine-only fields when not declared" do
    application = LabelApplication.new(
      beverage_type: "malt",
      brand_name: "ALPHA ALE",
      alcohol_content: nil,
      net_contents: "12 fl oz",
      applicant_name_address: "Alpha Brewing, Portland, OR"
    )

    evidence = Extraction::RegulatoryEvidenceSchema.response_schema(application: application)
                                                       .dig("properties", "regulatory_evidence")

    assert_includes evidence["required"], "brand_name"
    assert_includes evidence["required"], "government_warning"
    assert_not_includes evidence["required"], "alcohol_statement"
    assert_not_includes evidence["required"], "varietals"
    assert_not_includes evidence["required"], "vintage"
  end

  private

  def union_schema_count(value)
    case value
    when Hash
      current = value["type"].is_a?(Array) || value.key?("anyOf") ? 1 : 0
      current + value.values.sum { |entry| union_schema_count(entry) }
    when Array
      value.sum { |entry| union_schema_count(entry) }
    else
      0
    end
  end
end
