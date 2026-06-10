# frozen_string_literal: true

module Rules
  module Checks
    # Class/type designation: controlled-vocabulary validity, sufficiency,
    # origin qualifiers, commodity cross-check, designation/ABV consistency,
    # and the formula declared-class match.
    module Designation
      QUALIFIER_TOKENS = %w[type american brewed produced distilled blended made].freeze
      WINE_COLOR_WORDS = %w[red white rose pink amber].freeze

      module_function

      def checks(application, facts, rules)
        citation = rules.dig("designations", "citation")
        extracted = facts.class_type_designation

        if extracted.to_s.strip.empty?
          return [ FieldCheck.new(
            field: "class_type_designation", verdict: "fail", expected: "A class/type designation",
            extracted: nil, citation: citation, note: "No class or type designation found on the label"
          ) ]
        end

        result = []
        entry = lookup(extracted, rules)

        if entry
          result << vocabulary_check(application, extracted, entry, citation)
          result << origin_qualifier_check(application, extracted, entry, citation)
          result << min_proof_check(extracted, entry, facts, rules)
          result << abv_class_check(extracted, facts, application, rules) if rules["commodity"] == "wine"
        else
          result << unknown_designation_check(application, extracted, rules, citation)
        end

        result << declared_class_match(application, extracted)
        result.compact
      end

      def lookup(extracted, rules)
        normalized = fold_whisky(Parsing::TextNormalizer.normalize(extracted))
        entries = rules.dig("designations", "entries")

        # Exact vocabulary match first, then designation-contained match
        # ("Kentucky Straight Bourbon Whiskey" contains "Straight Bourbon Whisky"
        # only after whisky/whiskey folding).
        entries.find { |e| entry_names(e).any? { |n| n == normalized } } ||
          entries.find { |e| entry_names(e).any? { |n| normalized.end_with?(n) || normalized.include?(n) } }
      end

      def entry_names(entry)
        entry["names"].map { |n| fold_whisky(Parsing::TextNormalizer.normalize(n)) }
      end

      def fold_whisky(text)
        text.gsub("whiskey", "whisky")
      end

      def vocabulary_check(application, extracted, entry, citation)
        case entry["sufficient"]
        when true
          FieldCheck.new(field: "class_type_designation", verdict: "pass",
                         expected: "A recognized #{application.beverage_type} designation",
                         extracted: extracted, citation: citation, note: nil)
        when "conditional"
          FieldCheck.new(field: "class_type_designation", verdict: "needs_review",
                         expected: "A recognized #{application.beverage_type} designation",
                         extracted: extracted, citation: citation,
                         note: entry["note"] || entry["composition_rule"] || "Sufficiency is conditional - agent judgment required")
        else
          FieldCheck.new(field: "class_type_designation", verdict: "fail",
                         expected: "A sufficient class/type designation",
                         extracted: extracted, citation: citation,
                         note: entry["composition_rule"] || "This name is not sufficient alone as a class/type designation")
        end
      end

      def origin_qualifier_check(application, extracted, entry, citation)
        origin = entry["origin_rule"]
        return nil if origin.nil?
        return nil if origin["qualifier_when_elsewhere"].nil?

        produced_in = origin["produced_in"].to_s
        # Domestic products bearing a foreign-origin designation need a
        # qualifier; US-inclusive origins (e.g. Pilsner) are fine domestically.
        return nil if application.imported?
        return nil if produced_in.include?("United States")

        normalized = Parsing::TextNormalizer.normalize(extracted)
        return nil if QUALIFIER_TOKENS.any? { |t| normalized.include?(t) }

        FieldCheck.new(
          field: "designation_origin_qualifier", verdict: "fail",
          expected: "#{extracted} type / American #{extracted}", extracted: extracted,
          citation: citation,
          note: "#{origin['produced_in']}-origin designation on a domestic product requires a qualifier: #{origin['qualifier_when_elsewhere']}"
        )
      end

      def min_proof_check(extracted, entry, facts, rules)
        minimum = entry["min_bottling_abv"]
        return nil if minimum.nil?

        parsed = Parsing::AlcoholStatement.parse(facts.alcohol_statement)
        labeled = parsed&.percent
        return nil if labeled.nil?
        return nil if labeled >= minimum.to_f

        FieldCheck.new(
          field: "designation_minimum_abv", verdict: "fail",
          expected: "At least #{minimum}% ABV for #{extracted}",
          extracted: "#{labeled}%", citation: rules.dig("designations", "citation"),
          note: "This designation requires bottling at not less than #{minimum}% alcohol by volume"
        )
      end

      def abv_class_check(extracted, facts, application, rules)
        constraints = rules.dig("designations", "abv_class_constraints", "constraints")
        return nil if constraints.nil?

        normalized = Parsing::TextNormalizer.normalize(extracted)
        constraint = constraints.find { |c| normalized.include?(Parsing::TextNormalizer.normalize(c["designation"])) }
        return nil if constraint.nil?

        labeled = Parsing::AlcoholStatement.parse(facts.alcohol_statement)&.percent || application.alcohol_content&.to_f
        return nil if labeled.nil?

        ok = true
        ok &&= labeled >= constraint["min"].to_f if constraint["min"]
        ok &&= labeled > constraint["min_exclusive"].to_f if constraint["min_exclusive"]
        ok &&= labeled <= constraint["max"].to_f if constraint["max"]
        ok &&= labeled < constraint["max_exclusive"].to_f if constraint["max_exclusive"]
        return nil if ok

        FieldCheck.new(
          field: "designation_abv_class", verdict: "fail",
          expected: "#{constraint['designation']} within its class ABV limits",
          extracted: "#{labeled}%",
          citation: rules.dig("designations", "abv_class_constraints", "citation"),
          note: "#{labeled}% is outside the ABV limits for the designation #{constraint['designation']}"
        )
      end

      def unknown_designation_check(application, extracted, rules, citation)
        normalized = Parsing::TextNormalizer.normalize(extracted)

        if rules["commodity"] == "wine" && WINE_COLOR_WORDS.include?(normalized)
          return FieldCheck.new(
            field: "class_type_designation", verdict: "fail",
            expected: "#{extracted} Wine", extracted: extracted, citation: citation,
            note: "A color word alone is insufficient - it must be followed by 'Wine'"
          )
        end

        other = other_commodity_match(application, normalized)
        if other
          return FieldCheck.new(
            field: "class_type_designation", verdict: "fail",
            expected: "A #{application.beverage_type} designation", extracted: extracted,
            citation: citation,
            note: "This designation belongs to #{other} labeling, but the application declares #{application.beverage_type}"
          )
        end

        if rules["commodity"] == "wine"
          FieldCheck.new(
            field: "class_type_designation", verdict: "needs_review",
            expected: "A recognized wine designation", extracted: extracted, citation: citation,
            note: "Not a recognized class/type; may be a varietal designation, which requires an appellation of origin"
          )
        else
          FieldCheck.new(
            field: "class_type_designation", verdict: "needs_review",
            expected: "A recognized #{application.beverage_type} designation",
            extracted: extracted, citation: citation,
            note: "Not in the BAM designation vocabulary - agent judgment required"
          )
        end
      end

      def other_commodity_match(application, normalized)
        (Rules::Data::COMMODITIES - [ application.beverage_type ]).find do |other|
          Rules::Data.for(other).dig("designations", "entries").any? do |entry|
            entry_names(entry).any? { |n| fold_whisky(normalized) == n }
          end
        end
      end

      def declared_class_match(application, extracted)
        declared = application.declared_class_type
        return nil if declared.to_s.strip.empty?
        return nil if Parsing::TextNormalizer.equivalent?(declared, extracted)
        return nil if Parsing::TextNormalizer.normalize(extracted).include?(Parsing::TextNormalizer.normalize(declared))

        FieldCheck.new(
          field: "declared_class_type", verdict: "needs_review",
          expected: declared, extracted: extracted, citation: "TTB F 5100.51 item 4",
          note: "Label designation differs from the class/type declared on the formula"
        )
      end
    end
  end
end
