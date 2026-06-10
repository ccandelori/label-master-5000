# frozen_string_literal: true

module Rules
  # The compliance engine: pure evaluation of extracted label facts against
  # the application and the BAM rule data. No I/O, no API calls - every
  # verdict is reproducible from its inputs.
  module Engine
    module_function

    # Returns an array of FieldCheck. The caller derives the overall verdict
    # via FieldCheck.overall and owns persistence and presentation.
    def evaluate(application:, facts:)
      rules = Rules::Data.for(application.beverage_type)
      shared = Rules::Data.shared

      checks = []
      checks << Checks::Identity.brand_name(application, facts, rules)
      checks << Checks::Identity.fanciful_name(application, facts)
      checks << Checks::Identity.name_and_address(application, facts, rules)
      checks << Checks::Identity.country_of_origin(application, facts, rules)
      checks.concat Checks::Warning.checks(facts, shared)

      if wine_below_part_4?(application, facts, rules)
        checks << part_4_not_applicable(rules)
      else
        checks.concat Checks::NetContentsCheck.checks(application, facts, rules)
        checks.concat Checks::Alcohol.checks(application, facts, rules)
        checks.concat Checks::Designation.checks(application, facts, rules)
        checks.concat Checks::WineRules.checks(application, facts, rules) if application.wine?
        checks.concat Checks::SpiritsRules.checks(application, facts, rules) if application.spirits?
      end

      checks.concat Checks::Disclosures.checks(application, facts, rules)
      checks.compact
    end

    # Wine under 7% ABV falls outside 27 CFR Part 4 (FDA rules apply);
    # the health warning and disclosures still apply.
    def wine_below_part_4?(application, facts, rules)
      return false unless application.wine?

      threshold = rules.dig("coverage", "min_abv_for_part_4")
      return false if threshold.nil?

      abv = application.alcohol_content&.to_f ||
            Parsing::AlcoholStatement.parse(facts.alcohol_statement)&.percent
      !abv.nil? && abv < threshold.to_f
    end

    def part_4_not_applicable(rules)
      FieldCheck.new(
        field: "part_4_coverage", verdict: "not_applicable",
        expected: nil, extracted: nil,
        citation: rules.dig("coverage", "citation") || "BAM Vol 1 Introduction",
        note: "Wine under 7% ABV is outside 27 CFR Part 4; FDA labeling rules apply. Health warning still checked."
      )
    end
  end
end
