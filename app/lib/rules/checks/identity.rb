# frozen_string_literal: true

module Rules
  module Checks
    # Application-match checks for identity fields: brand name, fanciful
    # name, applicant name and address, and country of origin.
    module Identity
      module_function

      def brand_name(application, facts, rules)
        citation = rules.dig("designations", "citation").to_s.split(";").first
        expected = application.brand_name
        extracted = facts.brand_name

        if extracted.to_s.strip.empty?
          return FieldCheck.new(
            field: "brand_name", verdict: "fail", expected: expected, extracted: nil,
            citation: brand_citation(rules), note: "No brand name found on the label"
          )
        end

        match_verdict(
          field: "brand_name", expected: expected, extracted: extracted,
          citation: brand_citation(rules) || citation
        )
      end

      def fanciful_name(application, facts)
        expected = application.fanciful_name
        return nil if expected.to_s.strip.empty?

        match_verdict(
          field: "fanciful_name", expected: expected, extracted: facts.fanciful_name,
          citation: "TTB F 5100.31 item 7",
          missing_note: "Fanciful name on the application was not found on the label"
        )
      end

      def name_and_address(application, facts, rules)
        section = rules["name_and_address"]
        citation = section["citation"]
        expected = application.applicant_name_address
        extracted = facts.name_address_statement

        if extracted.to_s.strip.empty?
          return FieldCheck.new(
            field: "name_and_address", verdict: "fail", expected: expected, extracted: nil,
            citation: citation, note: "No name and address statement found on the label"
          )
        end

        phrases = application.imported? ? section["import_phrases"] : section["domestic_phrases"]
        phrases = Array(phrases) + Array(section["operation_phrases"])
        normalized = Parsing::TextNormalizer.normalize(extracted)
        phrase_present = phrases.any? { |p| normalized.include?(Parsing::TextNormalizer.normalize(p)) }

        case applicant_presence(expected, extracted)
        when :present
          if phrase_present
            FieldCheck.new(
              field: "name_and_address", verdict: "pass", expected: expected, extracted: extracted,
              citation: citation, note: nil
            )
          else
            FieldCheck.new(
              field: "name_and_address", verdict: phrase_required?(application) ? "fail" : "pass_with_note",
              expected: expected, extracted: extracted, citation: citation,
              note: "Statement lacks a required explanatory phrase such as #{phrases.first(3).join(', ')}"
            )
          end
        when :missing_place
          FieldCheck.new(
            field: "name_and_address", verdict: "needs_review", expected: expected, extracted: extracted,
            citation: citation,
            note: "Applicant name found, but the place of business (city and state) is not clearly on the label"
          )
        else
          FieldCheck.new(
            field: "name_and_address", verdict: "needs_review", expected: expected, extracted: extracted,
            citation: citation,
            note: "Label statement does not clearly contain the applicant name from the application"
          )
        end
      end

      # The label satisfies the regulation with the applicant's name (entity
      # suffixes like LLC optional) plus city and state - street address and
      # ZIP are application detail (27 CFR 4.35, 5.66, 7.66). Returns
      # :present, :missing_place, or :absent. When the application string
      # yields no parseable US place, falls back to whole-string word
      # matching, which cannot distinguish :missing_place.
      def applicant_presence(expected, extracted)
        parts = Parsing::NameAddress.parse(expected)
        return applicant_appears?(expected, extracted) ? :present : :absent if parts.state.nil?

        statement_tokens = Parsing::TextNormalizer.normalize(extracted).split(" ")
        return :absent unless name_found?(parts.name, statement_tokens, extracted)

        place_found = Parsing::NameAddress.state_present?(statement_tokens, parts.state) &&
                      (parts.city.nil? || Parsing::NameAddress.tokens_include?(statement_tokens, parts.city))
        place_found ? :present : :missing_place
      end

      # Most of the suffix-stripped name words must appear in the statement;
      # the label may drop "LLC" but not the name itself.
      def name_found?(name, statement_tokens, extracted)
        name_tokens = Parsing::NameAddress.name_tokens(name).reject { |w| w.length < 3 }
        return applicant_appears?(name, extracted) if name_tokens.empty?

        statement = statement_tokens.join(" ")
        name_tokens.count { |w| statement.include?(w) }.to_f / name_tokens.size >= 0.6
      end

      def country_of_origin(application, facts, rules)
        section = rules["country_of_origin"]
        citation = section["citation"]

        unless application.imported?
          return FieldCheck.new(
            field: "country_of_origin", verdict: "not_required", expected: nil,
            extracted: facts.country_of_origin_statement, citation: citation,
            note: "Domestic product"
          )
        end

        extracted = facts.country_of_origin_statement
        if extracted.to_s.strip.empty?
          return FieldCheck.new(
            field: "country_of_origin", verdict: "fail", expected: application.country_of_origin,
            extracted: nil, citation: citation,
            note: "Imported product without a country of origin statement"
          )
        end

        country = Parsing::TextNormalizer.normalize(application.country_of_origin)
        if Parsing::TextNormalizer.normalize(extracted).include?(country)
          FieldCheck.new(
            field: "country_of_origin", verdict: "pass", expected: application.country_of_origin,
            extracted: extracted, citation: citation, note: nil
          )
        else
          FieldCheck.new(
            field: "country_of_origin", verdict: "fail", expected: application.country_of_origin,
            extracted: extracted, citation: citation,
            note: "Statement does not name the application's country of origin"
          )
        end
      end

      def match_verdict(field:, expected:, extracted:, citation:, missing_note: nil)
        if extracted.to_s.strip.empty?
          return FieldCheck.new(
            field: field, verdict: "needs_review", expected: expected, extracted: nil,
            citation: citation, note: missing_note || "Not found on the label"
          )
        end

        if expected.to_s.strip == extracted.to_s.strip
          FieldCheck.new(field: field, verdict: "pass", expected: expected, extracted: extracted,
                         citation: citation, note: nil)
        elsif Parsing::TextNormalizer.equivalent?(expected, extracted)
          FieldCheck.new(field: field, verdict: "pass_with_note", expected: expected, extracted: extracted,
                         citation: citation,
                         note: "Same name, different casing or punctuation - treated as a match")
        else
          FieldCheck.new(field: field, verdict: "needs_review", expected: expected, extracted: extracted,
                         citation: citation,
                         note: "Differs from the application beyond casing and punctuation")
        end
      end

      def applicant_appears?(expected, extracted)
        expected_norm = Parsing::TextNormalizer.normalize(expected)
        extracted_norm = Parsing::TextNormalizer.normalize(extracted)
        return false if expected_norm.empty? || extracted_norm.empty?

        # The label statement rarely reproduces the application string exactly;
        # require most of the applicant words to appear in the statement.
        words = expected_norm.split(" ").reject { |w| w.length < 3 }
        return false if words.empty?

        hits = words.count { |w| extracted_norm.include?(w) }
        hits.to_f / words.size >= 0.6
      end

      def phrase_required?(application)
        # Malt: phrase is optional for domestic products (BAM Vol 3 1-2).
        # Wine and spirits: a preceding phrase is required.
        !(application.malt? && !application.imported?)
      end

      def brand_citation(rules)
        case rules["commodity"]
        when "malt" then "BAM Vol 3 1-1"
        when "wine" then "BAM Vol 1 1-1; 27 CFR 4.33"
        when "spirits" then "BAM Vol 2 1-1"
        end
      end
    end
  end
end
