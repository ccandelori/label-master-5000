# frozen_string_literal: true

module Extraction
  # The extraction prompt and response schema. The system prompt stays about
  # reading what is on the label; per-application search targets are
  # added to the user message by FieldGrounding so the rules boundary remains
  # stable while the VLM actively hunts for declared values.
  module Schema
    FIELD_KEYS = %w[
      brand_name fanciful_name class_type_designation alcohol_statement
      net_contents name_address_statement country_of_origin_statement
      government_warning commodity_statement appellation vintage
    ].freeze

    # Text labels preceding each image in a multi-image (front + back
    # label) request, indexed by page - 1. Shared by every connector so
    # the prompt's page semantics never drift between providers.
    PAGE_LABELS = [ "FRONT label (page 1):", "BACK label (page 2):" ].freeze

    FIELD_SCHEMA = {
      "type" => %w[object null],
      "additionalProperties" => false,
      "properties" => {
        "text" => { "type" => %w[string null] },
        "page" => { "type" => %w[integer null] },
        "confidence" => { "type" => %w[number null] }
      },
      "required" => %w[text page confidence]
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
        "image_width" => {
          "type" => "integer",
          "description" => "Width in pixels of the first image as you see it"
        },
        "image_height" => {
          "type" => "integer",
          "description" => "Height in pixels of the first image as you see it"
        },
        # Per-page image metadata for multi-image requests. Nullable
        # rather than optional: OpenAI strict mode requires every property
        # listed in required, and old payloads without the key stay valid
        # for consumers.
        "pages" => {
          "type" => %w[array null],
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "properties" => {
              "page" => { "type" => "integer" },
              "width" => { "type" => "integer" },
              "height" => { "type" => "integer" }
            },
            "required" => %w[page width height]
          },
          "description" => "One entry per image: its 1-based page and the pixel dimensions " \
                           "of that image as you see it"
        },
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
      "required" => %w[legible confidence image_width image_height pages fields varietals disclosures warning_attributes]
    }.freeze

    PROMPT = <<~PROMPT
      You are reading the artwork of an alcohol beverage label. Extract exactly
      what is printed - do not correct, complete, or normalize anything.

      First report image_width and image_height: the pixel dimensions of
      the first image exactly as you see it. When you are given more than
      one image (or a multi-page PDF), also fill pages: one entry per
      image with its 1-based page number and that image's pixel
      dimensions as you see it; otherwise set pages to null. Then, for
      each field, report the literal text as printed, the page number
      (1-based: the image as labeled, or the PDF page), and your
      confidence from 0 to 1. Use null for anything not present on the
      label. Do not return bounding boxes or coordinates; OCR supplies
      review geometry when it can ground the text.

      Field notes:
      - brand_name: the most prominent product name (largest, most prominent typography).
      - fanciful_name: a secondary product name, if any - a distinctive
        coined name for the product, not a marketing slogan, tagline, or
        seasonal-edition phrase. Null when only slogans appear.
      - class_type_designation: the product identity, e.g. "India Pale Ale",
        "Kentucky Straight Bourbon Whiskey", "Table Wine".
      - alcohol_statement: the full statement, e.g. "45% ALC./VOL. (90 PROOF)".
      - net_contents: e.g. "750 mL" or "1 PINT, 4 FL. OZ.".
      - name_address_statement: **Scan the entire label carefully (bottom, sides, back, small print) for the full bottler/importer/producer statement.** These almost always include a phrase such as "BOTTLED BY", "PRODUCED BY", "IMPORTED BY", "VINTED & BOTTLED BY", "BREWED BY", "PACKED BY", "MANUFACTURED BY", "MADE BY", etc. Extract the *entire contiguous block* verbatim, including the company name and full address as printed. Do not truncate.
      - country_of_origin_statement: e.g. "PRODUCT OF SCOTLAND". Look for origin claims, often near the name/address or in a dedicated statement.
      - government_warning: the complete health warning statement verbatim,
        preserving its capitalization. Usually in a box or distinct block; extract the full text including the "GOVERNMENT WARNING" prefix if present.
      - commodity_statement: e.g. "70% NEUTRAL SPIRITS DISTILLED FROM GRAIN".
      - appellation: a wine appellation of origin, e.g. "Napa Valley".
      - vintage: a wine vintage year as printed, e.g. "2021".
      - varietals: each grape variety named on the label.
      - disclosures: each standalone disclosure statement, e.g.
        "CONTAINS SULFITES", preserving capitalization.

      **Special instruction for reconciliation fields (name_address_statement, country_of_origin_statement, and any field that must match a declared value):** Be extremely thorough. These statements can be in small, stylized, or low-contrast text, on side panels, the back label, or near the bottom. Search *all text regions* of the image(s). Report the full exact printed wording.

      warning_attributes: assess visually where possible, otherwise null:
      - prefix_all_caps: is "GOVERNMENT WARNING" printed in all capitals?
      - prefix_bold: is that prefix in bold type relative to the rest?
      - continuous_paragraph: does the warning run as one continuous paragraph?
        Set false only when the warning is split into separate blocks, columns,
        bullets, or separated by intervening artwork/blank space. Normal line
        wrapping inside one warning block is still a continuous paragraph.

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
