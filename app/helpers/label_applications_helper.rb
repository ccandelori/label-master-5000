# frozen_string_literal: true

module LabelApplicationsHelper
  # Maps extraction payload keys to the field-check names shown in the
  # results table, so hovering a row highlights the right outline.
  EXTRACTION_FIELD_TO_CHECKS = {
    "brand_name" => %w[brand_name],
    "fanciful_name" => %w[fanciful_name],
    "class_type_designation" => %w[class_type_designation designation_origin_qualifier
                                   designation_minimum_abv designation_abv_class declared_class_type],
    "alcohol_statement" => %w[alcohol_content alcohol_content_tolerance alcohol_content_range
                              proof alcohol_content_tax_class],
    "net_contents" => %w[net_contents standards_of_fill net_contents_measurement_system net_contents_form],
    "name_address_statement" => %w[name_and_address],
    "country_of_origin_statement" => %w[country_of_origin],
    "government_warning" => %w[government_warning_text government_warning_prefix
                               government_warning_bold government_warning_paragraph],
    "commodity_statement" => %w[commodity_statement],
    "appellation" => %w[appellation semi_generic_appellation],
    "vintage" => %w[vintage_date vintage_appellation]
  }.freeze

  # Builds the JSON the bounding-box overlay renders: one entry per located
  # element, carrying the worst verdict among its associated checks plus the
  # note and citation for the click-through annotation.
  def bbox_data(verification)
    checks_by_field = verification.field_checks.index_by(&:field)
    payload = verification.extraction || {}
    # The coordinate basis the extractor reported its boxes in (the pixel
    # dimensions of the image as the model viewed it).
    basis = [ payload["image_width"] || 1000, payload["image_height"] || 1000 ]
    boxes = []

    (payload["fields"] || {}).each do |key, field|
      next if field.nil? || !valid_bbox?(field["bbox"])

      checks = Array(EXTRACTION_FIELD_TO_CHECKS[key]).filter_map { |f| checks_by_field[f] }
      worst = checks.max_by(&:severity)
      # A box renders only when a rules check stands behind it. The model
      # reads everything it can; without a check the read is noise here -
      # a marketing tagline mistaken for a fanciful name the application
      # never declared, say.
      next if worst.nil?

      boxes << {
        field: Array(EXTRACTION_FIELD_TO_CHECKS[key]).first || key,
        related_fields: Array(EXTRACTION_FIELD_TO_CHECKS[key]),
        label: field_label(key),
        bbox: field["bbox"],
        basis: field_basis(field) || basis,
        page: field["page"] || 1,
        verdict: worst.verdict,
        verdict_label: verdict_label(worst.verdict),
        note: worst.note,
        citation: worst.citation,
        expected: worst.expected,
        extracted: worst.extracted || field["text"]
      }
    end

    # One box per unique disclosure text, and only for texts a
    # disclosure_* check actually claimed: the model also reads
    # disclosure-shaped matter that no regulation asks for (bottle
    # deposit values, say), and those are noise here.
    disclosure_checks = verification.field_checks.select { |c| c.field.start_with?("disclosure_") }
    seen_disclosures = Set.new

    Array(payload["disclosures"]).each do |field|
      next if field.nil? || !valid_bbox?(field["bbox"])
      next unless seen_disclosures.add?(Parsing::TextNormalizer.normalize(field["text"]))

      check = disclosure_checks.find do |c|
        Parsing::TextNormalizer.equivalent?(c.extracted, field["text"])
      end
      next if check.nil?

      boxes << {
        field: check.field,
        related_fields: [ check.field ],
        label: "Disclosure",
        bbox: field["bbox"],
        basis: field_basis(field) || basis,
        page: field["page"] || 1,
        verdict: check.verdict,
        verdict_label: verdict_label(check.verdict),
        note: check.note || field["text"],
        citation: check.citation,
        expected: check.expected,
        extracted: field["text"]
      }
    end

    boxes
  end

  # The schema cannot enforce four-number arity (the structured-output API
  # limits minItems), so malformed boxes are dropped here.
  def valid_bbox?(bbox)
    bbox.is_a?(Array) && bbox.size == 4 && bbox.all? { |n| n.is_a?(Numeric) }
  end

  # OCR-grounded boxes carry their own coordinate basis (the raster
  # dimensions of their page); model boxes fall back to the payload-level
  # basis the extractor self-reported.
  def field_basis(field)
    basis = field["bbox_basis"]
    return nil unless basis.is_a?(Array) && basis.size == 2

    basis.all? { |n| n.is_a?(Numeric) && n.positive? } ? basis : nil
  end
end
