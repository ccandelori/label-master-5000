# frozen_string_literal: true

module Extraction
  # Answers "why does this field have this text and box" for one
  # application: the model's claim from the stored verification, what
  # every OCR pass actually read, and the scored match candidates the
  # grounder considered. Run via bin/rails "ocr:explain[SERIAL,field]".
  module Diagnostics
    module_function

    def explain(application:, field:)
      verification = application.verifications.order(created_at: :desc).first
      lines = [ "#{application.serial_number} - #{field}" ]

      if verification.nil? || verification.extraction.nil?
        return (lines << "no verification with extraction exists").join("\n")
      end

      lines << "verification: #{verification.created_at} (#{verification.extraction_reused? ? "reused" : "fresh"} extraction)"
      slot = verification.extraction.dig("fields", field)
      lines << "stored field: #{slot.nil? ? "nil (model read nothing)" : slot.slice("text", "bbox", "bbox_source", "bbox_basis", "page").inspect}"

      check = verification.field_checks.find { |c| c.field == field || c.field == "name_and_address" && field == "name_address_statement" }
      lines << "check: #{check ? "#{check.verdict} - #{check.note}" : "none issued"}"

      expected = expected_for(application, field)
      lines << "application declares: #{expected.inspect}"

      pages = OcrFactory.build.read(
        data: application.artwork.download,
        content_type: application.artwork.content_type
      )
      words = pages.flat_map(&:words)
      lines << "enriched OCR pool: #{words.size} entries across #{pages.size} page(s)"

      target = (expected.presence || slot&.fetch("text", nil)).to_s
      tokens = BboxGrounder.tokenize(target)
      if tokens.empty?
        lines << "nothing to match (no declared value and no model text)"
      else
        lines << "match target: #{tokens.inspect}"
        BboxGrounder.candidates(tokens, words, 5).each do |candidate|
          flag = candidate[:score] >= Rails.application.config.x.extraction.ocr_match_threshold ? "MATCH" : "below threshold"
          lines << format("  %.3f  %-16s %s  @%s",
                          candidate[:score], flag, candidate[:tokens].join(" ").first(60),
                          candidate[:words].first(3).map { |w| [ w.x, w.y ] }.inspect)
        end
        lines << "  (no windows in size range)" if BboxGrounder.candidates(tokens, words, 1).empty?
      end

      lines.join("\n")
    rescue OcrError => e
      (lines << "OCR unavailable: #{e.message}").join("\n")
    end

    def expected_for(application, field)
      case field
      when "fanciful_name" then application.fanciful_name
      when "brand_name" then application.brand_name
      when "name_address_statement" then application.applicant_name_address
      end
    end
  end
end
