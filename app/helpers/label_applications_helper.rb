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

  # Options for the validation refinement select. Every visible option runs
  # OCR first, then refines unresolved findings with the selected VLM.
  def demo_model_options
    demo_model_options_for(configured_refinement_model_value)
  end

  def demo_model_options_for(selected_value)
    config = Rails.application.config.x.extraction
    entries = refinement_model_entries(config)
    options = entries.map do |entry|
      [ "OCR + #{entry.fetch("label")} refinement", "#{entry.fetch("provider")}:#{entry.fetch("model")}" ]
    end
    options_for_select(options, selected_value)
  end

  def demo_model_value_for_verification(verification)
    verification_refinement_model_value(verification) || configured_refinement_model_value
  end

  # The menu label for a model id, for showing which model produced a
  # verification; ids outside the menu display as themselves.
  def demo_model_label(model_id)
    entry = Array(Rails.application.config.x.extraction.demo_models).find { |e| e["model"] == model_id }
    entry ? entry["label"] : model_id
  end

  def refinement_model_entries(config)
    configured = {
      "provider" => config.provider,
      "model" => config.model,
      "label" => demo_model_label(config.model)
    }
    entries = Array(config.demo_models)
    return entries if entries.any? { |entry| entry["provider"] == configured["provider"] && entry["model"] == configured["model"] }

    [ configured, *entries ]
  end

  def configured_refinement_model_value
    config = Rails.application.config.x.extraction
    "#{config.provider}:#{config.model}"
  end

  def verification_refinement_model_value(verification)
    extraction = verification&.extraction
    return nil unless extraction.is_a?(Hash)

    refinement = extraction["vlm_refinement"]
    return nil unless refinement.is_a?(Hash)

    provider = refinement["provider"]
    model = refinement["model"]
    return nil if provider.blank? || model.blank?

    "#{provider}:#{model}"
  end

  def verification_timing_lines(verification, attempt)
    [
      ocr_timing_line(attempt),
      vlm_refinement_timing_line(verification)
    ].compact
  end

  def ocr_timing_line(attempt)
    duration_ms = ocr_duration_ms(attempt)
    return nil if duration_ms.nil?

    "OCR #{duration_label(duration_ms)}"
  end

  def vlm_refinement_timing_line(verification)
    refinement = vlm_refinement_metadata(verification)
    return nil unless refinement

    model = refinement["model"]
    return nil if model.blank?

    status = refinement["status"].to_s
    duration_ms = numeric_ms(refinement["duration_ms"])
    suffix = duration_ms ? duration_label(duration_ms) : status.presence
    return nil if suffix.blank?

    "#{demo_model_label(model)} refinement #{suffix}"
  end

  def vlm_refinement_metadata(verification)
    extraction = verification&.extraction
    return nil unless extraction.is_a?(Hash)

    refinement = extraction["vlm_refinement"]
    refinement.is_a?(Hash) ? refinement : nil
  end

  def ocr_duration_ms(attempt)
    stage_timings = attempt&.stage_timings
    return nil unless stage_timings.is_a?(Hash)

    values = %w[ocr_ms ocr_escalation_ms].filter_map { |key| numeric_ms(stage_timings[key]) }
    return nil if values.empty?

    values.sum
  end

  def numeric_ms(value)
    return value if value.is_a?(Numeric)

    Float(value, exception: false)
  end

  def duration_label(duration_ms)
    "#{(duration_ms / 1000.0).round(1)}s"
  end

  def actionable_checks(verification)
    verification.field_checks.select { |check| %w[fail needs_review].include?(check.verdict) }
  end

  def quiet_findings_count(verification)
    verification.field_checks.count { |check| %w[pass pass_with_note not_required not_applicable].include?(check.verdict) }
  end

  def findings_groups(verification)
    sorted = actionable_checks(verification).sort_by { |check| -check.severity }
    [
      { title: "Failed", verdict_key: "fail", checks: sorted.select { |check| check.verdict == "fail" } },
      { title: "Needs review", verdict_key: "needs_review", checks: sorted.select { |check| check.verdict == "needs_review" } }
    ].reject { |group| group[:checks].empty? }
  end

  def quiet_findings_groups(verification)
    sorted = verification.field_checks.sort_by { |check| -check.severity }
    [
      { title: "Passing", verdict_key: "pass", checks: sorted.select { |check| %w[pass pass_with_note].include?(check.verdict) } },
      { title: "Informational", verdict_key: "not_required", checks: sorted.select { |check| %w[not_required not_applicable].include?(check.verdict) } }
    ].reject { |group| group[:checks].empty? }
  end

  def bbox_data(verification)
    checks_by_field = verification.field_checks.index_by(&:field)
    payload = verification.extraction || {}
    boxes = []

    application = verification.label_application

    (payload["fields"] || {}).each do |key, field|
      next if field.nil? || !valid_bbox?(field["bbox"])
      next unless field["bbox_source"] == "ocr"

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
        basis: field_basis(field) || page_basis(payload, field),
        page: field["page"] || 1,
        approximate: approximate?(field),
        verdict: worst.verdict,
        verdict_label: verdict_label(worst.verdict),
        note: worst.note,
        citation: worst.citation,
        expected: worst.expected,
        extracted: worst.extracted || field["text"],
        # The evidence clip: the artwork cut to this claimed region, so a
        # human verifies the find by looking at the actual pixels.
        crop_url: croppable?(application, field) ? label_application_field_crop_path(application, field: key) : nil,
        # Every check behind this element, worst first - one located
        # element can carry several verdicts (the government warning box
        # answers wording, prefix, bold, and paragraph checks), and the
        # popover accounts for each so the chip tally reconciles with
        # the verdict counts.
        checks: checks.sort_by { |c| -c.severity }.map { |c| check_detail(c) }
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
      next unless field["bbox_source"] == "ocr"
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
        basis: field_basis(field) || page_basis(payload, field),
        page: field["page"] || 1,
        approximate: approximate?(field),
        verdict: check.verdict,
        verdict_label: verdict_label(check.verdict),
        note: check.note || field["text"],
        citation: check.citation,
        expected: check.expected,
        extracted: field["text"],
        checks: [ check_detail(check) ]
      }
    end

    boxes
  end

  # Reverse of EXTRACTION_FIELD_TO_CHECKS: the extraction key whose
  # located element answers this check.
  def extraction_key_for(check_field)
    EXTRACTION_FIELD_TO_CHECKS.find { |_key, checks| checks.include?(check_field) }&.first
  end

  # The evidence clip for a check: the artwork cut to the region its value
  # was read from. An approximate (model-estimated) region is not evidence,
  # so it gets the caption instead of a crop; nil when nothing was located
  # or the artwork is not an image.
  def field_crop_tag(application, verification, check_field)
    key = extraction_key_for(check_field)
    slot = key && verification.extraction&.dig("fields", key)
    return nil unless slot.is_a?(Hash) && valid_bbox?(slot["bbox"])
    return nil if approximate?(slot)
    return nil unless croppable?(application, slot)

    image_tag label_application_field_crop_path(application, field: key),
              class: "mb-1.5 max-h-14 w-auto max-w-full rounded border border-line bg-white",
              loading: "lazy", alt: "Label region read for #{field_label(check_field)}"
  end

  def check_detail(check)
    {
      field: check.field,
      label: field_label(check.field),
      verdict: check.verdict,
      verdict_label: verdict_label(check.verdict),
      note: check.note,
      citation: check.citation,
      expected: check.expected,
      extracted: check.extracted
    }
  end

  # The schema cannot enforce four-number arity (the structured-output API
  # limits minItems), so malformed boxes are dropped here.
  def valid_bbox?(bbox)
    bbox.is_a?(Array) && bbox.size == 4 && bbox.all? { |n| n.is_a?(Numeric) }
  end

  # OCR-grounded boxes carry their own coordinate basis: the raster
  # dimensions of their page.
  def field_basis(field)
    basis = field["bbox_basis"]
    return nil unless basis.is_a?(Array) && basis.size == 2

    basis.all? { |n| n.is_a?(Numeric) && n.positive? } ? basis : nil
  end

  def page_basis(payload, field)
    Extraction::PageBasis.dimensions(payload, field["page"] || 1) || [ 1000, 1000 ]
  end

  # An evidence crop exists only when the field was anchored to OCR geometry
  # and its page has a standalone image blob to cut from.
  def croppable?(application, field)
    return false if approximate?(field)

    attachment = (field["page"] || 1) == 1 ? application&.artwork : application&.back_artwork
    (field["page"] || 1) <= 2 && attachment&.attached? && attachment.image?
  end

  # Only OCR-anchored boxes are evidence. VLM coordinates are ignored.
  def approximate?(field)
    field["bbox_source"] != "ocr"
  end
end
