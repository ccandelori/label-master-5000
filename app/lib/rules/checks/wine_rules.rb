# frozen_string_literal: true

module Rules
  module Checks
    # Wine-only cross-field rules: vintage and varietal each require an
    # appellation, and label values must match the application's wine fields.
    module WineRules
      module_function

      def checks(application, facts, rules)
        result = []
        result << vintage_requires_appellation(facts, rules)
        result << varietal_requires_appellation(facts, rules)
        result << semi_generic_requires_appellation(facts, rules)
        result << vintage_match(application, facts)
        result << appellation_match(application, facts)
        result << varietals_match(application, facts)
        result << brand_label_placement(facts)
        result.compact
      end

      def vintage_requires_appellation(facts, rules)
        return nil if facts.vintage_year.nil?
        return nil unless facts.appellation.to_s.strip.empty?

        rule = presence_rule(rules, "vintage_requires_appellation")
        FieldCheck.new(
          field: "vintage_appellation", verdict: "fail",
          expected: "An appellation of origin in direct conjunction with the designation",
          extracted: "Vintage #{facts.vintage_year} without an appellation",
          citation: rule["citation"], note: rule["note"]
        )
      end

      def varietal_requires_appellation(facts, rules)
        return nil if Array(facts.varietals).empty?
        return nil unless facts.appellation.to_s.strip.empty?

        rule = presence_rule(rules, "varietal_requires_appellation")
        FieldCheck.new(
          field: "varietal_appellation", verdict: "fail",
          expected: "An appellation of origin",
          extracted: "Varietal designation (#{facts.varietals.join(', ')}) without an appellation",
          citation: rule["citation"], note: rule["note"]
        )
      end

      def semi_generic_requires_appellation(facts, rules)
        designation = Parsing::TextNormalizer.normalize(facts.class_type_designation)
        return nil if designation.empty?

        entry = rules.dig("designations", "entries").find do |e|
          e["kind"] == "semi_generic" &&
            e["names"].any? do |n|
              Rules::Checks::Designation.designation_name_present?(designation, Parsing::TextNormalizer.normalize(n))
            end
        end
        return nil if entry.nil?
        return nil unless facts.appellation.to_s.strip.empty?
        return nil if protected_origin_statement?(entry, facts)

        rule = presence_rule(rules, "semi_generic_requires_appellation")
        FieldCheck.new(
          field: "semi_generic_appellation", verdict: "fail",
          expected: "An appellation of origin with a semi-generic designation",
          extracted: facts.class_type_designation,
          citation: rule["citation"], note: rule["note"]
        )
      end

      def protected_origin_statement?(entry, facts)
        produced_in = entry.dig("origin_rule", "produced_in")
        return false if produced_in.to_s.strip.empty?

        origin = Parsing::TextNormalizer.normalize(facts.country_of_origin_statement)
        origin.include?(Parsing::TextNormalizer.normalize(produced_in))
      end

      def vintage_match(application, facts)
        expected = application.vintage_year
        return nil if expected.nil? && facts.vintage_year.nil?

        citation = "TTB F 5100.31 (proposed) item 15; 27 CFR 4.27"
        if expected.nil?
          FieldCheck.new(field: "vintage_date", verdict: "needs_review", expected: nil,
                         extracted: facts.vintage_year.to_s, citation: citation,
                         note: "Label shows a vintage the application does not declare")
        elsif facts.vintage_year.nil?
          FieldCheck.new(field: "vintage_date", verdict: "fail", expected: expected.to_s,
                         extracted: nil, citation: citation,
                         note: "Application declares a vintage that is not on the label")
        elsif expected == facts.vintage_year
          FieldCheck.new(field: "vintage_date", verdict: "pass", expected: expected.to_s,
                         extracted: facts.vintage_year.to_s, citation: citation, note: nil)
        else
          FieldCheck.new(field: "vintage_date", verdict: "fail", expected: expected.to_s,
                         extracted: facts.vintage_year.to_s, citation: citation,
                         note: "Vintage on the label does not match the application")
        end
      end

      def appellation_match(application, facts)
        expected = application.appellation
        return nil if expected.to_s.strip.empty? && facts.appellation.to_s.strip.empty?

        citation = "TTB F 5100.31 item 11; 27 CFR 4.25"
        if expected.to_s.strip.empty?
          FieldCheck.new(field: "appellation", verdict: "needs_review", expected: nil,
                         extracted: facts.appellation, citation: citation,
                         note: "Label shows an appellation the application does not declare")
        elsif facts.appellation.to_s.strip.empty?
          FieldCheck.new(field: "appellation", verdict: "fail", expected: expected,
                         extracted: nil, citation: citation,
                         note: "Application declares an appellation that is not on the label")
        else
          Identity.match_verdict(field: "appellation", expected: expected,
                                 extracted: facts.appellation, citation: citation,
                                 model_text: facts.model_texts["appellation"],
                                 confidence: facts.field_confidences["appellation"])
        end
      end

      def varietals_match(application, facts)
        expected = Array(application.varietals).reject { |v| v.to_s.strip.empty? }
        extracted = Array(facts.varietals).reject { |v| v.to_s.strip.empty? }
        return nil if expected.empty? && extracted.empty?

        citation = "TTB F 5100.31 item 10; 27 CFR 4.23"
        qualified = extracted.select { |v| expected.any? { |e| qualified_varietal_match?(e, v) } }
        unlisted = extracted.reject { |v| expected.any? { |e| varietal_match?(e, v) } }
        missing = expected.reject { |e| extracted.any? { |v| varietal_match?(e, v) } }

        if unlisted.empty? && missing.empty?
          if qualified.any?
            FieldCheck.new(field: "varietals", verdict: "pass_with_note", expected: expected.join(", "),
                           extracted: extracted.join(", "), citation: citation,
                           note: "Label varietal wording includes the declared varietal with additional modifier text")
          else
            FieldCheck.new(field: "varietals", verdict: "pass", expected: expected.join(", "),
                           extracted: extracted.join(", "), citation: citation, note: nil)
          end
        elsif unlisted.any?
          FieldCheck.new(field: "varietals", verdict: "fail", expected: expected.join(", "),
                         extracted: extracted.join(", "), citation: citation,
                         note: "Label varietals not listed on the application: #{unlisted.join(', ')}")
        else
          FieldCheck.new(field: "varietals", verdict: "needs_review", expected: expected.join(", "),
                         extracted: extracted.join(", "), citation: citation,
                         note: "Application lists varietals not found on the label: #{missing.join(', ')}")
        end
      end

      # Items 27 CFR 4.32(a) requires on the brand label, by facts field.
      BRAND_LABEL_ITEMS = {
        "brand_name" => "brand name",
        "class_type_designation" => "class/type designation",
        "alcohol_statement" => "alcohol content statement"
      }.freeze

      # Only meaningful when the extraction saw a back label (any field on
      # page 2 or later); placement on a single-label product is trivially
      # satisfied and emits nothing. Violations are examiner judgment -
      # which physical label is the brand label is a visual call.
      def brand_label_placement(facts)
        pages = facts.field_pages
        return nil unless pages.values.any? { |page| page.to_i > 1 }

        misplaced = BRAND_LABEL_ITEMS.keys.select { |key| pages[key].to_i > 1 }
        expected = "Brand name, class/type designation, and alcohol content on the brand label"
        if misplaced.empty?
          FieldCheck.new(field: "brand_label_placement", verdict: "pass", expected: expected,
                         extracted: "All on the brand label", citation: "27 CFR 4.32(a)", note: nil)
        else
          names = misplaced.map { |key| BRAND_LABEL_ITEMS[key] }
          FieldCheck.new(field: "brand_label_placement", verdict: "needs_review", expected: expected,
                         extracted: "On the back label: #{names.join(', ')}",
                         citation: "27 CFR 4.32(a)",
                         note: "Required on the brand label but found on the back label: #{names.join(', ')} - confirm which label is the brand label")
        end
      end

      def presence_rule(rules, key)
        Array(rules["presence_rules"]).find { |r| r["key"] == key } || {}
      end

      def varietal_match?(expected, extracted)
        Parsing::TextNormalizer.equivalent?(expected, extracted) ||
          qualified_varietal_match?(expected, extracted)
      end

      def qualified_varietal_match?(expected, extracted)
        expected_tokens = Parsing::TextNormalizer.normalize(expected).split
        extracted_tokens = Parsing::TextNormalizer.normalize(extracted).split
        return false if expected_tokens.empty? || extracted_tokens.size <= expected_tokens.size

        extracted_tokens.each_cons(expected_tokens.size).any? { |tokens| tokens == expected_tokens }
      end
    end
  end
end
