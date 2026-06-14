# frozen_string_literal: true

module Rules
  module Checks
    # Application-match checks for identity fields: brand name, fanciful
    # name, applicant name and address, and country of origin.
    module Identity
      GENERIC_IMPORTER_NAME_WORDS = %w[
        america american americas beverage beverages company co corporation incorporated inc
        import imported importer importers imports llc ltd supply wine wines spirits
      ].to_set.freeze

      module_function

      def brand_name(application, facts, rules)
        citation = rules.dig("designations", "citation").to_s.split(";").first
        expected = application.brand_name
        extracted = facts.brand_name

        if extracted.to_s.strip.empty?
          if facts.weak_field?("brand_name")
            return FieldCheck.new(
              field: "brand_name", verdict: "needs_review", expected: expected, extracted: nil,
              citation: brand_citation(rules), note: "Brand name evidence is ambiguous; confirm the label visually"
            )
          end

          return FieldCheck.new(
            field: "brand_name", verdict: "needs_review", expected: expected, extracted: nil,
            citation: brand_citation(rules), note: "Brand name was not found; confirm the label visually"
          )
        end

        match_verdict(
          field: "brand_name", expected: expected, extracted: extracted,
          citation: brand_citation(rules) || citation,
          model_text: facts.model_texts["brand_name"],
          confidence: facts.field_confidences["brand_name"]
        )
      end

      def fanciful_name(application, facts)
        expected = application.fanciful_name
        return nil if expected.to_s.strip.empty?

        if composite_fanciful_match?(expected, facts)
          return FieldCheck.new(
            field: "fanciful_name", verdict: "pass_with_note", expected: expected,
            extracted: facts.fanciful_name, citation: "TTB F 5100.31 item 7",
            note: "Declared fanciful name is satisfied across visible identity fields"
          )
        end

        match_verdict(
          field: "fanciful_name", expected: expected, extracted: facts.fanciful_name,
          citation: "TTB F 5100.31 item 7",
          missing_note: "Fanciful name on the application was not found on the label",
          model_text: facts.model_texts["fanciful_name"],
          confidence: facts.field_confidences["fanciful_name"]
        )
      end

      def name_and_address(application, facts, rules)
        section = rules["name_and_address"]
        citation = section["citation"]
        expected = application.applicant_name_address
        extracted = facts.name_address_statement

        if extracted.to_s.strip.empty?
          if facts.weak_field?("name_address_statement")
            return FieldCheck.new(
              field: "name_and_address", verdict: "needs_review", expected: expected, extracted: nil,
              citation: citation, note: "Name and address evidence is ambiguous; confirm the label visually"
            )
          end

          return FieldCheck.new(
            field: "name_and_address", verdict: "needs_review", expected: expected, extracted: nil,
            citation: citation, note: "Name and address statement was not found; confirm the label visually"
          )
        end

        phrases = application.imported? ? section["import_phrases"] : section["domestic_phrases"]
        phrases = Array(phrases) + Array(section["operation_phrases"])
        normalized = Parsing::TextNormalizer.normalize(extracted)
        phrase_present = phrases.any? { |p| normalized.include?(Parsing::TextNormalizer.normalize(p)) }

        presence = applicant_presence(expected, extracted)
        case presence
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
          if shortened_importer_match?(application, expected, extracted, phrase_present)
            return FieldCheck.new(
              field: "name_and_address", verdict: "pass_with_note", expected: expected, extracted: extracted,
              citation: citation,
              note: "Importer statement uses a shortened importer name, with matching city and state"
            )
          end

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

        applicant_place_found?(parts, statement_tokens) ? :present : :missing_place
      end

      # Most of the suffix-stripped name words must appear in the statement;
      # the label may drop "LLC" but not the name itself.
      def name_found?(name, statement_tokens, extracted)
        name_tokens = Parsing::NameAddress.name_tokens(name).reject { |w| w.length < 3 }
        return applicant_appears?(name, extracted) if name_tokens.empty?

        statement = statement_tokens.join(" ")
        name_tokens.count { |w| statement.include?(w) }.to_f / name_tokens.size >= 0.6
      end

      def shortened_importer_match?(application, expected, extracted, phrase_present)
        return false unless application.imported?
        return false unless phrase_present

        parts = Parsing::NameAddress.parse(expected)
        return false if parts.state.nil?

        statement_tokens = Parsing::TextNormalizer.normalize(extracted).split(" ")
        applicant_place_found?(parts, statement_tokens) &&
          shortened_importer_name_found?(parts.name, statement_tokens)
      end

      def applicant_place_found?(parts, statement_tokens)
        Parsing::NameAddress.state_present?(statement_tokens, parts.state) &&
          (parts.city.nil? || Parsing::NameAddress.tokens_include?(statement_tokens, parts.city))
      end

      def shortened_importer_name_found?(name, statement_tokens)
        name_tokens = Parsing::NameAddress.name_tokens(name).reject do |word|
          word.length < 4 || GENERIC_IMPORTER_NAME_WORDS.include?(word)
        end
        return false if name_tokens.empty?

        statement_tokens.include?(name_tokens.first)
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
            field: "country_of_origin", verdict: "needs_review", expected: application.country_of_origin,
            extracted: nil, citation: citation,
            note: "No country of origin statement was read; confirm whether it appears on another label panel"
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

      # model_text is the vision model's reading of a slot whose text was
      # replaced by OCR-located print: the located form carries the true
      # geometry but sometimes OCR character noise, so a declared value
      # matching either form is a match, not a discrepancy.
      def match_verdict(field:, expected:, extracted:, citation:, missing_note: nil, model_text: nil, confidence: nil)
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
                         note: "Same name, different casing, spacing, or punctuation - treated as a match")
        elsif Parsing::TextNormalizer.equivalent?(expected, model_text)
          FieldCheck.new(field: field, verdict: "pass_with_note", expected: expected, extracted: extracted,
                         citation: citation,
                         note: "Matches the application as read by the vision model (#{model_text.to_s.strip}); " \
                               "the OCR-located print differs only by likely character noise")
        elsif high_confidence_near_match?(expected, extracted, confidence)
          FieldCheck.new(field: field, verdict: "pass_with_note", expected: expected, extracted: extracted,
                         citation: citation,
                         note: "Near match at high extraction confidence - treated as likely OCR/model character noise")
        else
          FieldCheck.new(field: field, verdict: "needs_review", expected: expected, extracted: extracted,
                         citation: citation,
                         note: "Differs from the application beyond casing and punctuation")
        end
      end

      def high_confidence_near_match?(expected, extracted, confidence)
        confidence.is_a?(Numeric) &&
          confidence >= 0.9 &&
          Parsing::TextNormalizer.near_equivalent?(expected, extracted)
      end

      def composite_fanciful_match?(expected, facts)
        expected_tokens = identity_tokens(expected)
        return false if expected_tokens.size < 3
        return false if facts.fanciful_name.to_s.strip.empty?

        visible = [
          facts.brand_name,
          facts.class_type_designation,
          facts.fanciful_name,
          facts.model_texts["brand_name"],
          facts.model_texts["class_type_designation"],
          facts.model_texts["fanciful_name"]
        ].join(" ")
        visible_tokens = identity_tokens(visible)
        return false if visible_tokens.empty?

        (expected_tokens - visible_tokens).empty?
      end

      def identity_tokens(text)
        Parsing::TextNormalizer.normalize(text).split.reject { |token| token.length < 2 }
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
