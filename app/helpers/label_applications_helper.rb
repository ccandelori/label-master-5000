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
    boxes = []

    (payload["fields"] || {}).each do |key, field|
      next if field.nil? || field["bbox"].nil?

      checks = Array(EXTRACTION_FIELD_TO_CHECKS[key]).filter_map { |f| checks_by_field[f] }
      worst = checks.max_by(&:severity)
      boxes << {
        field: Array(EXTRACTION_FIELD_TO_CHECKS[key]).first || key,
        related_fields: Array(EXTRACTION_FIELD_TO_CHECKS[key]),
        label: field_label(key),
        bbox: field["bbox"],
        page: field["page"] || 1,
        verdict: worst&.verdict || "pass",
        verdict_label: worst ? verdict_label(worst.verdict) : "Read",
        note: worst&.note,
        citation: worst&.citation
      }
    end

    Array(payload["disclosures"]).each_with_index do |field, index|
      next if field.nil? || field["bbox"].nil?

      boxes << {
        field: "disclosure_#{index}",
        related_fields: [],
        label: "Disclosure",
        bbox: field["bbox"],
        page: field["page"] || 1,
        verdict: "pass",
        verdict_label: "Read",
        note: field["text"],
        citation: nil
      }
    end

    boxes
  end
end
