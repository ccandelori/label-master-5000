# frozen_string_literal: true

module Rules
  module Checks
    # Conditional disclosures (sulfites, FD&C Yellow #5, saccharin,
    # aspartame, cochineal/carmine, coloring). Two-tier strictness:
    # with formula data the trigger is knowable and absence can fail;
    # without it, only present-but-malformed text is actionable.
    module Disclosures
      FORMULA_FLAGS = {
        "fd_c_yellow_5" => :contains_fd_c_yellow_5,
        "cochineal_carmine" => :contains_cochineal_carmine,
        "sulfites" => :contains_sulfites_10ppm,
        "saccharin" => :contains_saccharin,
        "aspartame" => :contains_aspartame,
        "coloring" => :contains_added_coloring
      }.freeze

      module_function

      def checks(application, facts, rules)
        Array(rules["disclosures"]).filter_map do |disclosure|
          check_one(application, facts, rules, disclosure)
        end
      end

      def check_one(application, facts, rules, disclosure)
        key = disclosure["key"]
        found = find_statement(facts, disclosure)
        flag = formula_flag(application, key)

        if found
          format_verdict(key, found, disclosure, flag)
        else
          absence_verdict(application, rules, disclosure, key, flag)
        end
      end

      def find_statement(facts, disclosure)
        candidates = Array(facts.disclosures)
        keywords = keyword_set(disclosure)
        matches = candidates.select do |text|
          normalized = Parsing::TextNormalizer.normalize(text)
          keywords.any? { |k| normalized.include?(k) }
        end
        matches.find { |text| permitted_form?(text, disclosure) } || matches.first
      end

      def keyword_set(disclosure)
        case disclosure["key"]
        when "sulfites" then %w[sulfite sulfiting sulphite]
        when "fd_c_yellow_5" then [ "yellow" ]
        when "saccharin" then [ "saccharin" ]
        when "aspartame" then %w[phenylketonurics phenylalanine aspartame]
        when "cochineal_carmine" then %w[cochineal carmine]
        when "coloring" then %w[colored color]
        when "wood_treatment" then [ "wood" ]
        else [ Parsing::TextNormalizer.normalize(disclosure["key"]) ]
        end
      end

      def format_verdict(key, found, disclosure, flag)
        texts = Array(disclosure["required_text"])
        pattern = disclosure["pattern_allowed"]
        matches = permitted_form?(found, disclosure)

        if matches && flag == false
          FieldCheck.new(
            field: "disclosure_#{key}", verdict: "needs_review", expected: "No #{key} disclosure expected",
            extracted: found, citation: disclosure["citation"],
            note: "Label carries this disclosure but the formula declares the ingredient absent"
          )
        elsif matches
          FieldCheck.new(
            field: "disclosure_#{key}", verdict: "pass", expected: texts.first || pattern,
            extracted: found, citation: disclosure["citation"], note: nil
          )
        else
          verdict = flag == true ? "fail" : "needs_review"
          FieldCheck.new(
            field: "disclosure_#{key}", verdict: verdict, expected: texts.first || pattern,
            extracted: found, citation: disclosure["citation"],
            note: caps_ok?(disclosure, found) ?
              "Disclosure present but not in a permitted form" :
              "Disclosure must appear in capital letters"
          )
        end
      end

      def absence_verdict(application, rules, disclosure, key, flag)
        if flag == true
          FieldCheck.new(
            field: "disclosure_#{key}", verdict: "fail",
            expected: Array(disclosure["required_text"]).first || disclosure["pattern_allowed"],
            extracted: nil, citation: disclosure["citation"],
            note: "The formula declares this ingredient; the disclosure is mandatory"
          )
        elsif key == "sulfites" && rules["commodity"] == "wine"
          FieldCheck.new(
            field: "disclosure_sulfites", verdict: rules.dig("sulfite_policy", "missing_statement_verdict") || "needs_review",
            expected: "CONTAINS SULFITES", extracted: nil,
            citation: rules.dig("sulfite_policy", "citation"),
            note: "No sulfite statement; TTB approves wine labels without one only with a laboratory waiver"
          )
        elsif flag == false
          FieldCheck.new(
            field: "disclosure_#{key}", verdict: "pass", expected: nil, extracted: nil,
            citation: disclosure["citation"],
            note: "Formula declares the ingredient absent; no disclosure required"
          )
        else
          FieldCheck.new(
            field: "disclosure_#{key}", verdict: "not_required", expected: nil, extracted: nil,
            citation: disclosure["citation"],
            note: "Applicability unknown without formula data; nothing on the label to check"
          )
        end
      end

      def formula_flag(application, key)
        attribute = FORMULA_FLAGS[key]
        return nil if attribute.nil?

        application.public_send(attribute)
      end

      def pattern_match?(pattern, found)
        return false if pattern.to_s.strip.empty?

        prefix = Parsing::TextNormalizer.normalize(pattern.gsub("___", ""))
        Parsing::TextNormalizer.normalize(found).start_with?(prefix)
      end

      def permitted_form?(found, disclosure)
        texts = Array(disclosure["required_text"])
        pattern = disclosure["pattern_allowed"]
        matches = texts.any? do |text|
          Parsing::TextNormalizer.equivalent?(text, found) ||
            Parsing::TextNormalizer.normalize(found).include?(Parsing::TextNormalizer.normalize(text))
        end
        matches ||= pattern_match?(pattern, found)
        matches && caps_ok?(disclosure, found)
      end

      def caps_ok?(disclosure, found)
        return true unless disclosure["all_caps_required"]

        found == found.upcase
      end
    end
  end
end
