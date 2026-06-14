# frozen_string_literal: true

module Rules
  module Checks
    # The government health warning: exact statutory text in code, visual
    # format attributes best-effort from the extractor.
    module Warning
      module_function

      def checks(facts, shared_rules)
        warning_rules = shared_rules["health_warning"]
        statutory = warning_rules["statutory_text"]
        citation = warning_rules["citation"]
        format_citation = warning_rules.dig("format", "citation")

        result = Parsing::WarningComparator.compare(facts.government_warning_text, statutory)
        model_text = facts.model_texts["government_warning"]
        model_result = Parsing::WarningComparator.compare(model_text, statutory) if model_text.to_s.strip.present?

        [
          text_check(facts, result, model_result, model_text, statutory, citation),
          prefix_check(facts, result, model_result, model_text, format_citation),
          bold_check(facts, format_citation),
          paragraph_check(facts, format_citation)
        ].compact
      end

      def text_check(facts, result, model_result, model_text, statutory, citation)
        if facts.government_warning_text.to_s.strip.empty?
          if facts.weak_field?("government_warning")
            return FieldCheck.new(
              field: "government_warning_text", verdict: "needs_review", expected: statutory, extracted: nil,
              citation: citation, note: "Government warning evidence is ambiguous; confirm the label visually"
            )
          end

          FieldCheck.new(
            field: "government_warning_text", verdict: "needs_review", expected: statutory, extracted: nil,
            citation: citation, note: "No government warning statement found by extraction; confirm visually"
          )
        elsif result.text_matches
          FieldCheck.new(
            field: "government_warning_text", verdict: "pass", expected: statutory,
            extracted: facts.government_warning_text, citation: citation, note: nil
          )
        elsif model_result&.text_matches
          FieldCheck.new(
            field: "government_warning_text", verdict: "pass_with_note", expected: statutory,
            extracted: facts.government_warning_text, citation: citation,
            note: "Matches the statutory warning as read by the vision model (#{model_text.to_s.strip}); " \
                  "the OCR-located print differs only by likely character noise"
          )
        elsif ocr_noise_match?(facts.government_warning_text, statutory)
          FieldCheck.new(
            field: "government_warning_text", verdict: "pass_with_note", expected: statutory,
            extracted: facts.government_warning_text, citation: citation,
            note: "Matches the statutory warning except for likely single-character OCR noise"
          )
        elsif trailing_truncation?(facts.government_warning_text, statutory)
          FieldCheck.new(
            field: "government_warning_text", verdict: "needs_review", expected: statutory,
            extracted: facts.government_warning_text, citation: citation,
            note: "Warning text appears truncated; confirm the missing trailing words visually"
          )
        elsif model_only_warning_read?(facts)
          FieldCheck.new(
            field: "government_warning_text", verdict: "needs_review", expected: statutory,
            extracted: facts.government_warning_text, citation: citation,
            note: "The model-only warning read differs from the statutory text and is not OCR-verified; " \
                  "confirm the wording visually"
          )
        else
          FieldCheck.new(
            field: "government_warning_text", verdict: "fail", expected: statutory,
            extracted: facts.government_warning_text, citation: citation,
            note: diff_note(result)
          )
        end
      end

      def prefix_check(facts, result, model_result, model_text, citation)
        return nil if facts.government_warning_text.to_s.strip.empty?

        if result.prefix_all_caps
          FieldCheck.new(
            field: "government_warning_prefix", verdict: "pass", expected: Parsing::WarningComparator::PREFIX,
            extracted: extracted_prefix(facts), citation: citation, note: nil
          )
        elsif model_result&.text_matches && model_result.prefix_all_caps
          FieldCheck.new(
            field: "government_warning_prefix", verdict: "pass_with_note", expected: Parsing::WarningComparator::PREFIX,
            extracted: extracted_prefix(facts), citation: citation,
            note: "Prefix is compliant as read by the vision model (#{model_text.to_s.strip}); " \
                  "the OCR-located print differs only by likely character noise"
          )
        elsif !result.text_matches && ocr_noise_match?(facts.government_warning_text, Rules::Data.statutory_warning_text)
          FieldCheck.new(
            field: "government_warning_prefix", verdict: "pass_with_note", expected: Parsing::WarningComparator::PREFIX,
            extracted: extracted_prefix(facts), citation: citation,
            note: "Prefix differs from GOVERNMENT WARNING only by likely single-character OCR noise"
          )
        elsif model_only_warning_read?(facts)
          FieldCheck.new(
            field: "government_warning_prefix", verdict: "needs_review", expected: Parsing::WarningComparator::PREFIX,
            extracted: extracted_prefix(facts), citation: citation,
            note: "Warning prefix capitalization is based on a model-only read and is not OCR-verified"
          )
        else
          FieldCheck.new(
            field: "government_warning_prefix", verdict: "fail", expected: Parsing::WarningComparator::PREFIX,
            extracted: extracted_prefix(facts), citation: citation,
            note: "GOVERNMENT WARNING must appear in capital letters"
          )
        end
      end

      def bold_check(facts, citation)
        return nil if facts.government_warning_text.to_s.strip.empty?
        return nil if facts.warning_prefix_bold == true

        FieldCheck.new(
          field: "government_warning_bold", verdict: "needs_review",
          expected: "GOVERNMENT WARNING in bold type", extracted: nil, citation: citation,
          note: facts.warning_prefix_bold == false ?
            "The prefix does not appear to be in bold type - confirm visually" :
            "Bold type could not be assessed from the artwork - confirm visually"
        )
      end

      def paragraph_check(facts, citation)
        return nil unless facts.warning_continuous_paragraph == false
        return nil if Parsing::WarningComparator.compare(
          facts.government_warning_text, Rules::Data.statutory_warning_text
        ).text_matches

        FieldCheck.new(
          field: "government_warning_paragraph", verdict: "needs_review",
          expected: "Statement as one continuous paragraph", extracted: nil, citation: citation,
          note: "The warning does not appear to run as a continuous paragraph - confirm visually"
        )
      end

      def diff_note(result)
        parts = [ "Wording differs from the statutory text" ]
        parts << "missing: #{result.missing_words.first(6).join(' ')}" if result.missing_words.any?
        parts << "unexpected: #{result.extra_words.first(6).join(' ')}" if result.extra_words.any?
        parts.join("; ")
      end

      def extracted_prefix(facts)
        facts.government_warning_text.to_s.strip[0, 20]
      end

      def model_only_warning_read?(facts)
        facts.field_sources["government_warning"].to_s == "model"
      end

      def ocr_noise_match?(extracted, statutory)
        extracted_words = Parsing::WarningComparator.words(extracted)
        statutory_words = Parsing::WarningComparator.words(statutory)
        return false unless extracted_words.size == statutory_words.size

        extracted_words.zip(statutory_words).all? do |actual, expected|
          actual == expected || single_character_noise?(actual, expected)
        end
      end

      def single_character_noise?(actual, expected)
        return false if actual == expected
        return false if (actual.length - expected.length).abs > 1

        if actual.length == expected.length
          return actual.chars.zip(expected.chars).count { |a, b| a != b } <= 1
        end

        shorter, longer = [ actual, expected ].sort_by(&:length)
        index_short = 0
        index_long = 0
        edits = 0

        while index_short < shorter.length && index_long < longer.length
          if shorter[index_short] == longer[index_long]
            index_short += 1
            index_long += 1
          else
            edits += 1
            return false if edits > 1

            index_long += 1
          end
        end

        true
      end

      def trailing_truncation?(extracted, statutory)
        extracted_words = Parsing::WarningComparator.words(extracted)
        statutory_words = Parsing::WarningComparator.words(statutory)
        return false if extracted_words.empty? || extracted_words.size >= statutory_words.size

        statutory_words.first(extracted_words.size) == extracted_words
      end
    end
  end
end
