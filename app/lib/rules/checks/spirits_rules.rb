# frozen_string_literal: true

module Rules
  module Checks
    # Spirits-only rules: the commodity statement required by blended and
    # neutral-spirit classes, and cocktail component declarations.
    module SpiritsRules
      module_function

      def checks(application, facts, rules)
        result = []
        result << commodity_statement(application, facts, rules)
        result << cocktail_declaration(facts, rules)
        result.compact
      end

      def commodity_statement(application, facts, rules)
        return nil if Designation.specialty_declared_class?(application)

        designation = Designation.fold_whisky(Parsing::TextNormalizer.normalize(facts.class_type_designation))
        return nil if designation.empty?

        section = rules["commodity_statement"]
        group = matching_group(designation, section)
        return nil if group.nil?

        group_name, group_rules = group
        statement = facts.commodity_statement

        if statement.to_s.strip.empty?
          return FieldCheck.new(
            field: "commodity_statement", verdict: "fail",
            expected: group_rules["note"], extracted: nil, citation: section["citation"],
            note: "This class requires a commodity statement disclosing the neutral spirits source"
          )
        end

        normalized = Parsing::TextNormalizer.normalize(statement)
        valid =
          if group_name == "group_1"
            statement.match?(/\d+(\.\d+)?\s*%/) && normalized.include?("neutral spirits")
          else
            normalized.include?("distilled from")
          end

        if valid
          FieldCheck.new(field: "commodity_statement", verdict: "pass",
                         expected: group_rules["note"], extracted: statement,
                         citation: section["citation"], note: nil)
        else
          FieldCheck.new(field: "commodity_statement", verdict: "fail",
                         expected: group_rules["note"], extracted: statement,
                         citation: section["citation"],
                         note: "Commodity statement present but not in the required form")
        end
      end

      def matching_group(designation, section)
        %w[group_1 group_2].each do |group_name|
          classes = Array(section.dig(group_name, "classes"))
          hit = classes.any? do |klass|
            normalized = Designation.fold_whisky(Parsing::TextNormalizer.normalize(klass.sub(/ produced by .+\z/, "")))
            designation == normalized || designation.include?(normalized)
          end
          return [ group_name, section[group_name] ] if hit
        end
        nil
      end

      def cocktail_declaration(facts, rules)
        designation = Parsing::TextNormalizer.normalize(facts.class_type_designation)
        return nil if designation.empty?

        cocktails = rules.dig("designations", "cocktails")
        names = Array(cocktails["names"]).map { |n| Parsing::TextNormalizer.normalize(n) }
        return nil unless names.any? { |n| designation.include?(n) }
        return nil if designation.include?("made with")

        FieldCheck.new(
          field: "cocktail_declaration", verdict: "fail",
          expected: "Cocktail name with its spirits declaration, e.g. 'Margarita Made With Tequila'",
          extracted: facts.class_type_designation, citation: cocktails["citation"],
          note: cocktails["note"]
        )
      end
    end
  end
end
