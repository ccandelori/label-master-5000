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

        [
          text_check(facts, result, statutory, citation),
          prefix_check(facts, result, format_citation),
          bold_check(facts, format_citation),
          paragraph_check(facts, format_citation)
        ].compact
      end

      def text_check(facts, result, statutory, citation)
        if facts.government_warning_text.to_s.strip.empty?
          FieldCheck.new(
            field: "government_warning_text", verdict: "fail", expected: statutory, extracted: nil,
            citation: citation, note: "No government warning statement found on the label"
          )
        elsif result.text_matches
          FieldCheck.new(
            field: "government_warning_text", verdict: "pass", expected: statutory,
            extracted: facts.government_warning_text, citation: citation, note: nil
          )
        else
          FieldCheck.new(
            field: "government_warning_text", verdict: "fail", expected: statutory,
            extracted: facts.government_warning_text, citation: citation,
            note: diff_note(result)
          )
        end
      end

      def prefix_check(facts, result, citation)
        return nil if facts.government_warning_text.to_s.strip.empty?

        if result.prefix_all_caps
          FieldCheck.new(
            field: "government_warning_prefix", verdict: "pass", expected: Parsing::WarningComparator::PREFIX,
            extracted: extracted_prefix(facts), citation: citation, note: nil
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
    end
  end
end
