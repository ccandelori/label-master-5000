# frozen_string_literal: true

module Extraction
  # Post-processes a VLM payload using only text the model already reported.
  # This is a slot-correction pass, not a hidden extractor: it can move a
  # matching printed statement into the field the rules engine consumes, but it
  # cannot fabricate evidence that was not in the model output.
  module VlmReconciler
    Candidate = Data.define(:text, :bbox, :page, :confidence)

    TEXT_MATCH_THRESHOLD = 0.75
    ALCOHOL_EPSILON = Rules::Checks::Alcohol::MATCH_EPSILON

    TEXT_FIELDS = {
      "brand_name" => :brand_name,
      "fanciful_name" => :fanciful_name,
      "class_type_designation" => :declared_class_type,
      "net_contents" => :net_contents,
      "country_of_origin_statement" => :country_of_origin,
      "appellation" => :appellation
    }.freeze

    module_function

    def reconcile(payload:, application:)
      refined = payload.deep_dup
      candidates = candidates_from(refined)
      return refined if candidates.empty?

      fields = fields_for(refined)
      reconcile_alcohol_statement(fields: fields, candidates: candidates, application: application)
      reconcile_text_fields(fields: fields, candidates: candidates, application: application)
      refined.merge("fields" => fields)
    end

    def ground(payload:, evidence:, threshold:)
      refined = payload.deep_dup
      fields = fields_for(refined).transform_values do |field|
        ground_field(field: field, evidence: evidence, threshold: threshold)
      end
      refined["fields"] = fields
      %w[varietals disclosures].each do |key|
        next unless refined[key].is_a?(Array)

        refined[key] = refined[key].map { |field| ground_field(field: field, evidence: evidence, threshold: threshold) }
      end
      refined
    end

    def reconcile_alcohol_statement(fields:, candidates:, application:)
      expected = application.alcohol_content&.to_f
      return if expected.nil?

      current = field_candidate(fields["alcohol_statement"])
      return if current && alcohol_matches?(current.text, expected)

      match = candidates.find { |candidate| alcohol_matches?(candidate.text, expected) }
      fields["alcohol_statement"] = located_field(match, "vlm_reconciled") if match
    end

    def reconcile_text_fields(fields:, candidates:, application:)
      TEXT_FIELDS.each do |field, attribute|
        expected = application.public_send(attribute).to_s.strip
        next if expected.empty?

        current = field_candidate(fields[field])
        next if current && text_matches?(current.text, expected)

        match = best_text_match(candidates: candidates, expected: expected)
        fields[field] = located_field(match, "vlm_reconciled") if match
      end
    end

    def best_text_match(candidates:, expected:)
      target_tokens = tokens(expected)
      return nil if target_tokens.empty?

      scored = candidates.map do |candidate|
        [ overlap_score(target_tokens, tokens(candidate.text)), candidate ]
      end
      score, candidate = scored.max_by(&:first)
      score && score >= TEXT_MATCH_THRESHOLD ? candidate : nil
    end

    def text_matches?(text, expected)
      Parsing::TextNormalizer.equivalent?(text, expected) ||
        overlap_score(tokens(expected), tokens(text)) >= TEXT_MATCH_THRESHOLD
    end

    def alcohol_matches?(text, expected)
      parsed = Parsing::AlcoholStatement.parse(text)
      return false if parsed.nil?
      return true if parsed.percent && (parsed.percent - expected).abs <= ALCOHOL_EPSILON
      return false if parsed.range.nil?

      parsed.range.first <= expected && expected <= parsed.range.last
    end

    def candidates_from(payload)
      fields = fields_for(payload)
      field_candidates = fields.values.filter_map { |value| field_candidate(value) }
      varietals = Array(payload["varietals"]).filter_map { |value| field_candidate(value) }
      disclosures = Array(payload["disclosures"]).filter_map { |value| field_candidate(value) }
      unique_candidates(field_candidates + varietals + disclosures)
    end

    def field_candidate(value)
      return nil unless value.is_a?(Hash)

      text = value["text"].to_s.strip
      return nil if text.empty?

      Candidate.new(
        text: text,
        bbox: value["bbox"],
        page: value["page"],
        confidence: value["confidence"]
      )
    end

    def located_field(candidate, source)
      {
        "text" => candidate.text,
        "bbox" => candidate.bbox,
        "bbox_source" => "model",
        "page" => candidate.page,
        "confidence" => candidate.confidence,
        "source" => source
      }
    end

    def ground_field(field:, evidence:, threshold:)
      return field unless field.is_a?(Hash)

      text = field["text"].to_s.strip
      return field if text.empty?

      match = supported_match(field: field, evidence: evidence, threshold: threshold)
      return ocr_grounded_field(field: field, match: match, evidence: evidence) if match
      return ambiguous_field(field: field, source: "vlm_region") if valid_region?(field: field, evidence: evidence)

      ambiguous_field(field: field, source: "vlm_unsupported")
    end

    def supported_match(field:, evidence:, threshold:)
      text = field["text"].to_s
      if field["text"].to_s.strip.present? && field["text"].to_s.include?("%")
        alcohol_match = alcohol_evidence_match(text: text, evidence: evidence)
        return alcohol_match if alcohol_match
      end

      matches = CandidateMatcher.find(query: text, evidence: evidence, threshold: threshold, limit: 1)
      return nil if matches.empty?

      match = matches.first
      return nil if government_warning_field?(field) && warning_word_overlap(text, match.text) < 0.6

      match
    end

    def alcohol_evidence_match(text:, evidence:)
      parsed = Parsing::AlcoholStatement.parse(text)
      return nil if parsed.nil?

      evidence.lines.each do |line|
        candidate = Parsing::AlcoholStatement.parse(line.text)
        next if candidate.nil?
        next unless same_alcohol_statement?(parsed, candidate)

        return CandidateMatcher::Match.new(
          text: line.text,
          normalized_text: line.normalized_text,
          confidence: line.confidence,
          bbox: line.bbox,
          page: line.page,
          match_score: 1.0
        )
      end

      nil
    end

    def same_alcohol_statement?(left, right)
      return true if left.percent && right.percent && (left.percent - right.percent).abs <= ALCOHOL_EPSILON
      return true if left.range && right.percent && left.range.first <= right.percent && right.percent <= left.range.last
      return true if right.range && left.percent && right.range.first <= left.percent && left.percent <= right.range.last
      return false if left.range.nil? || right.range.nil?

      [ left.range.first, right.range.first ].max <= [ left.range.last, right.range.last ].min
    end

    def ocr_grounded_field(field:, match:, evidence:)
      text = match.text
      original_text = field["text"].to_s.strip
      grounded = field.merge(
        "text" => text,
        "bbox" => bbox_array(match.bbox),
        "bbox_basis" => bbox_basis(match: match, evidence: evidence),
        "bbox_source" => "ocr",
        "page" => match.page,
        "confidence" => match.confidence,
        "source" => "ocr_grounded",
        "match_score" => match.match_score
      )
      return grounded if Parsing::TextNormalizer.equivalent?(text, original_text)

      grounded.merge("model_text" => original_text)
    end

    def ambiguous_field(field:, source:)
      {
        "text" => nil,
        "bbox" => field["bbox"],
        "bbox_source" => field["bbox"].present? ? "model" : nil,
        "page" => field["page"],
        "confidence" => "ambiguous",
        "source" => source,
        "model_text" => field["text"].to_s.strip,
        "evidence_note" => source == "vlm_region" ? "VLM region present but OCR did not confirm text" : "VLM text not found in OCR evidence"
      }.compact
    end

    def valid_region?(field:, evidence:)
      bbox = bbox_from(field["bbox"])
      return false if bbox.nil?

      page = evidence.page(number: field["page"].to_i)
      return false if page.nil?

      page_box = OcrEvidenceStore::Bbox.new(x: 0, y: 0, width: page.width, height: page.height)
      page_box.intersects?(bbox)
    end

    def bbox_from(value)
      return nil unless value.is_a?(Array) && value.size == 4

      x, y, width, height = value.map { |part| Integer(part, exception: false) }
      return nil if [ x, y, width, height ].any?(&:nil?)
      return nil unless width.positive? && height.positive?

      OcrEvidenceStore::Bbox.new(x: x, y: y, width: width, height: height)
    end

    def bbox_array(bbox)
      [ bbox.x, bbox.y, bbox.width, bbox.height ]
    end

    def bbox_basis(match:, evidence:)
      page = evidence.page(number: match.page)
      return nil if page.nil?

      [ page.width, page.height ]
    end

    def government_warning_field?(field)
      field["field"] == "government_warning" ||
        field["source_field"] == "government_warning" ||
        field["text"].to_s.match?(/government\s+warning/i)
    end

    def warning_word_overlap(left, right)
      left_words = Parsing::WarningComparator.words(left).uniq
      right_words = Parsing::WarningComparator.words(right).uniq
      return 0.0 if left_words.empty? || right_words.empty?

      (left_words & right_words).size.to_f / left_words.size
    end

    def fields_for(payload)
      payload["fields"].is_a?(Hash) ? payload["fields"] : {}
    end

    def unique_candidates(candidates)
      candidates.uniq { |candidate| [ candidate.text, candidate.bbox, candidate.page ] }
    end

    def tokens(text)
      Parsing::TextNormalizer.normalize(text).split
    end

    def overlap_score(target_tokens, candidate_tokens)
      return 0.0 if target_tokens.empty? || candidate_tokens.empty?

      target_set = target_tokens.uniq
      candidate_set = candidate_tokens.uniq
      (target_set & candidate_set).size.to_f / target_set.size
    end
  end
end
