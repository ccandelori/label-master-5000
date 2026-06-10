# frozen_string_literal: true

module Extraction
  # The extraction prompt and response schema. The extractor reads what is
  # on the label and where - it knows nothing about compliance rules or the
  # application, by design (data minimization and a stable rules boundary).
  module Schema
    FIELD_KEYS = %w[
      brand_name fanciful_name class_type_designation alcohol_statement
      net_contents name_address_statement country_of_origin_statement
      government_warning commodity_statement appellation vintage
    ].freeze

    FIELD_SCHEMA = {
      "type" => %w[object null],
      "additionalProperties" => false,
      "properties" => {
        "text" => { "type" => %w[string null] },
        # Normalized coordinates: the API may resize the image before the
        # model sees it, so pixel coordinates would be in an unknown basis.
        # 0-1000 is resolution-independent. The structured-output API only
        # supports minItems of 0 or 1, so the four-number arity is asked for
        # in the description and enforced at render time (bbox_data drops
        # malformed boxes).
        "bbox" => {
          "type" => %w[array null],
          "items" => { "type" => "number" },
          "description" => "Exactly four numbers [x, y, width, height] in normalized coordinates " \
                           "from 0 to 1000, where (0, 0) is the top-left corner and 1000 spans " \
                           "the full image width or height"
        },
        "page" => { "type" => %w[integer null] },
        "confidence" => { "type" => %w[number null] }
      },
      "required" => %w[text bbox page confidence]
    }.freeze

    # One shared $defs entry instead of inlining FIELD_SCHEMA thirteen
    # times: the API compiles the schema to a grammar and rejects overly
    # large ones ("compiled grammar is too large").
    FIELD_REF = { "$ref" => "#/$defs/located_field" }.freeze

    RESPONSE_SCHEMA = {
      "type" => "object",
      "$defs" => { "located_field" => FIELD_SCHEMA },
      "additionalProperties" => false,
      "properties" => {
        "legible" => { "type" => "boolean" },
        "confidence" => { "type" => "number" },
        "fields" => {
          "type" => "object",
          "additionalProperties" => false,
          "properties" => FIELD_KEYS.index_with { FIELD_REF },
          "required" => FIELD_KEYS
        },
        "varietals" => { "type" => "array", "items" => FIELD_REF },
        "disclosures" => { "type" => "array", "items" => FIELD_REF },
        "warning_attributes" => {
          "type" => "object",
          "additionalProperties" => false,
          "properties" => {
            "prefix_all_caps" => { "type" => %w[boolean null] },
            "prefix_bold" => { "type" => %w[boolean null] },
            "continuous_paragraph" => { "type" => %w[boolean null] }
          },
          "required" => %w[prefix_all_caps prefix_bold continuous_paragraph]
        }
      },
      "required" => %w[legible confidence fields varietals disclosures warning_attributes]
    }.freeze

    PROMPT = <<~PROMPT
      You are reading the artwork of an alcohol beverage label. Extract exactly
      what is printed - do not correct, complete, or normalize anything.

      For each field report the literal text as printed, a bounding box
      [x, y, width, height] in normalized coordinates (0 to 1000, where
      (0, 0) is the top-left corner and 1000 spans the full image width or
      height), the page number (1-based; always 1 for a single image), and
      your confidence from 0 to 1. Use null for anything not present on the
      label.

      Field notes:
      - brand_name: the most prominent product name.
      - fanciful_name: a secondary product name, if any.
      - class_type_designation: the product identity, e.g. "India Pale Ale",
        "Kentucky Straight Bourbon Whiskey", "Table Wine".
      - alcohol_statement: the full statement, e.g. "45% ALC./VOL. (90 PROOF)".
      - net_contents: e.g. "750 mL" or "1 PINT, 4 FL. OZ.".
      - name_address_statement: the full bottler/importer statement including
        any phrase such as "BOTTLED BY" or "IMPORTED BY".
      - country_of_origin_statement: e.g. "PRODUCT OF SCOTLAND".
      - government_warning: the complete health warning statement verbatim,
        preserving its capitalization.
      - commodity_statement: e.g. "70% NEUTRAL SPIRITS DISTILLED FROM GRAIN".
      - appellation: a wine appellation of origin, e.g. "Napa Valley".
      - vintage: a wine vintage year as printed, e.g. "2021".
      - varietals: each grape variety named on the label.
      - disclosures: each standalone disclosure statement, e.g.
        "CONTAINS SULFITES", preserving capitalization.

      warning_attributes: assess visually where possible, otherwise null:
      - prefix_all_caps: is "GOVERNMENT WARNING" printed in all capitals?
      - prefix_bold: is that prefix in bold type relative to the rest?
      - continuous_paragraph: does the warning run as one continuous paragraph?

      Set legible to false and lower confidence when glare, blur, angle, or
      resolution prevent a trustworthy reading.

      Respond with JSON only, matching the provided schema.
    PROMPT

    MATCH_JUDGMENT_PROMPT = <<~PROMPT
      Two strings are being compared on an alcohol label application. Decide
      whether they plainly refer to the same thing (allowing abbreviation,
      reordering, or formatting differences) or are genuinely different.
      Respond with JSON only: {"same_entity": true|false, "rationale": "one sentence"}.
    PROMPT
  end
end
