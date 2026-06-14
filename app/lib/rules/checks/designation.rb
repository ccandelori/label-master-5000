# frozen_string_literal: true

module Rules
  module Checks
    # Class/type designation: controlled-vocabulary validity, sufficiency,
    # origin qualifiers, commodity cross-check, designation/ABV consistency,
    # and the formula declared-class match.
    module Designation
      QUALIFIER_TOKENS = %w[type american brewed produced distilled blended made].freeze
      COMPONENT_SPIRIT_TERMS = [
        "seltzer", "soda", "spritz", "spritzer", "cocktail", "margarita",
        "mule", "highball", "cooler", "lemonade", "punch", "tea", "ready to drink", "rtd"
      ].freeze
      SPECIALTY_CLASS_TERMS = [
        "specialty", "specialties", "proprietary", "proprietaries",
        "cocktail", "cocktails", "seltzer", "cooler", "ready to drink", "rtd"
      ].freeze
      WINE_COLOR_WORDS = %w[red white rose pink amber].freeze

      module_function

      def checks(application, facts, rules)
        citation = rules.dig("designations", "citation")
        extracted = facts.class_type_designation
        fallback_slot = nil

        if extracted.to_s.strip.empty? && lookup(facts.fanciful_name, rules)
          extracted = facts.fanciful_name
          fallback_slot = "fanciful-name slot"
        end

        if extracted.to_s.strip.empty?
          if facts.weak_field?("class_type_designation")
            return [ FieldCheck.new(
              field: "class_type_designation", verdict: "needs_review", expected: "A class/type designation",
              extracted: nil, citation: citation, note: "Class/type designation evidence is ambiguous; confirm visually"
            ) ]
          end

          return [ FieldCheck.new(
            field: "class_type_designation", verdict: "needs_review", expected: "A class/type designation",
            extracted: nil, citation: citation, note: "No class or type designation found by extraction; confirm visually"
          ) ]
        end

        result = []
        entry = lookup(extracted, rules)

        if entry
          result << vocabulary_check(application, extracted, entry, citation, fallback_slot)
          result << origin_qualifier_check(application, extracted, entry, citation)
          result << min_proof_check(application, extracted, entry, facts, rules)
          result << abv_class_check(extracted, facts, application, rules) if rules["commodity"] == "wine"
        else
          result << unknown_designation_check(application, facts, extracted, rules, citation)
        end

        result << declared_class_match(application, extracted, facts.model_texts["class_type_designation"])
        result.compact
      end

      def lookup(extracted, rules)
        normalized = fold_whisky(Parsing::TextNormalizer.normalize(extracted))
        entries = rules.dig("designations", "entries")

        # Exact vocabulary match first, then designation-contained match
        # ("Kentucky Straight Bourbon Whiskey" contains "Straight Bourbon Whisky"
        # only after whisky/whiskey folding).
        entries.find { |e| entry_names(e).any? { |n| n == normalized } } ||
          entries.find { |e| entry_names(e).any? { |n| designation_name_present?(normalized, n) } }
      end

      def entry_names(entry)
        entry["names"].map { |n| fold_whisky(Parsing::TextNormalizer.normalize(n)) }
      end

      def designation_name_present?(text, name)
        return false if text.empty? || name.empty?
        return true if text == name

        text.start_with?("#{name} ") ||
          text.end_with?(" #{name}") ||
          text.include?(" #{name} ")
      end

      def fold_whisky(text)
        text.gsub("whiskey", "whisky")
      end

      def vocabulary_check(application, extracted, entry, citation, fallback_slot)
        case entry["sufficient"]
        when true
          if fallback_slot
            return FieldCheck.new(field: "class_type_designation", verdict: "pass_with_note",
                                  expected: "A recognized #{application.beverage_type} designation",
                                  extracted: extracted, citation: citation,
                                  note: "Recognized designation was read from the #{fallback_slot}")
          end

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

      def min_proof_check(application, extracted, entry, facts, rules)
        minimum = entry["min_bottling_abv"]
        return nil if minimum.nil?
        return nil if specialty_declared_class?(application)
        return nil if cocktail_designation?(extracted, rules)
        return nil if component_spirit_designation?(extracted, entry)

        parsed = Parsing::AlcoholStatement.parse(facts.alcohol_statement)
        labeled = parsed&.percent
        return nil if labeled.nil?
        return nil if labeled >= minimum.to_f

        verdict = application.alcohol_content.nil? ? "needs_review" : "fail"
        note = if application.alcohol_content.nil?
                 "This designation normally requires at least #{minimum}% ABV, but the application does not state alcohol content; confirm the OCR read visually"
               else
                 "This designation requires bottling at not less than #{minimum}% alcohol by volume"
               end

        FieldCheck.new(
          field: "designation_minimum_abv", verdict: verdict,
          expected: "At least #{minimum}% ABV for #{extracted}",
          extracted: "#{labeled}%", citation: rules.dig("designations", "citation"),
          note: note
        )
      end

      def cocktail_designation?(extracted, rules)
        cocktails = rules.dig("designations", "cocktails")
        names = Array(cocktails&.fetch("names", nil)).map { |name| Parsing::TextNormalizer.normalize(name) }
        normalized = Parsing::TextNormalizer.normalize(extracted)
        normalized.include?("made with") && names.any? { |name| normalized.include?(name) }
      end

      def component_spirit_designation?(extracted, entry)
        normalized = Parsing::TextNormalizer.normalize(extracted)
        return false unless COMPONENT_SPIRIT_TERMS.any? { |term| normalized.include?(term) }

        entry_names(entry).any? { |name| normalized.include?(name) }
      end

      def specialty_declared_class?(application)
        declared = Parsing::TextNormalizer.normalize(application.declared_class_type)
        return false if declared.empty?

        SPECIALTY_CLASS_TERMS.any? { |term| declared.include?(term) } ||
          declared.include?("under 48 proof")
      end

      def abv_class_check(extracted, facts, application, rules)
        constraints = rules.dig("designations", "abv_class_constraints", "constraints")
        return nil if constraints.nil?

        normalized = Parsing::TextNormalizer.normalize(extracted)
        constraint = constraints.find do |c|
          designation_name_present?(normalized, Parsing::TextNormalizer.normalize(c["designation"]))
        end
        return nil if constraint.nil?

        labeled = Parsing::AlcoholStatement.parse(facts.alcohol_statement)&.percent || application.alcohol_content&.to_f
        return nil if labeled.nil?

        ok = true
        ok &&= labeled >= constraint["min"].to_f if constraint["min"]
        ok &&= labeled > constraint["min_exclusive"].to_f if constraint["min_exclusive"]
        ok &&= labeled <= constraint["max"].to_f if constraint["max"]
        ok &&= labeled < constraint["max_exclusive"].to_f if constraint["max_exclusive"]
        return nil if ok

        verdict = application.alcohol_content.nil? && application.actual_alcohol_content.nil? ? "needs_review" : "fail"
        FieldCheck.new(
          field: "designation_abv_class", verdict: verdict,
          expected: "#{constraint['designation']} within its class ABV limits",
          extracted: "#{labeled}%",
          citation: rules.dig("designations", "abv_class_constraints", "citation"),
          note: "#{labeled}% is outside the ABV limits for the designation #{constraint['designation']}"
        )
      end

      def unknown_designation_check(application, facts, extracted, rules, citation)
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

        if rules["commodity"] == "wine" && varietal_designation_with_appellation?(application, facts, normalized)
          return FieldCheck.new(
            field: "class_type_designation", verdict: "pass_with_note",
            expected: "A recognized wine designation", extracted: extracted, citation: citation,
            note: "Treated as an open-set varietal designation with appellation evidence"
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

      def varietal_designation_with_appellation?(application, facts, normalized)
        return false if facts.appellation.to_s.strip.empty? && application.appellation.to_s.strip.empty?

        varietals = (Array(application.varietals) + Array(facts.varietals))
                    .map { |v| Parsing::TextNormalizer.normalize(v) }
                    .reject(&:empty?)
        varietals.any? { |varietal| normalized.include?(varietal) }
      end

      def other_commodity_match(application, normalized)
        (Rules::Data::COMMODITIES - [ application.beverage_type ]).find do |other|
          Rules::Data.for(other).dig("designations", "entries").any? do |entry|
            entry_names(entry).any? { |n| fold_whisky(normalized) == n }
          end
        end
      end

      def declared_class_match(application, extracted, model_text)
        declared = application.declared_class_type
        return nil if declared.to_s.strip.empty?
        return nil if Parsing::TextNormalizer.equivalent?(declared, extracted)
        return nil if Parsing::TextNormalizer.normalize(extracted).include?(Parsing::TextNormalizer.normalize(declared))
        return nil if same_designation_entry?(application, declared, extracted)
        # The vision model's reading of the same print also satisfies the
        # declared match - OCR character noise is not a formula mismatch.
        return nil if Parsing::TextNormalizer.equivalent?(declared, model_text)

        FieldCheck.new(
          field: "declared_class_type", verdict: "needs_review",
          expected: declared, extracted: extracted, citation: "TTB F 5100.51 item 4",
          note: "Label designation differs from the class/type declared on the formula"
        )
      end

      def same_designation_entry?(application, left, right)
        rules = Rules::Data.for(application.beverage_type)
        left_entry = lookup(left, rules)
        right_entry = lookup(right, rules)
        !left_entry.nil? && left_entry.equal?(right_entry)
      end
    end
  end
end
