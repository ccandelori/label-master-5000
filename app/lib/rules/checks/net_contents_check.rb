# frozen_string_literal: true

module Rules
  module Checks
    # Net contents: application match, measurement-system rules, and the
    # metric standards of fill (with BAM-vs-current-regulation notes).
    module NetContentsCheck
      FILL_TOLERANCE_ML = 1.0

      module_function

      def checks(application, facts, rules)
        section = rules["net_contents"]
        citation = section["citation"]
        expected = application.net_contents
        extracted = facts.net_contents

        if extracted.to_s.strip.empty?
          return [ missing_check(application, expected, citation) ]
        end

        expected_volume = Parsing::NetContents.parse(expected)
        extracted_volume = Parsing::NetContents.parse(extracted)

        if extracted_volume.nil?
          return [ FieldCheck.new(
            field: "net_contents", verdict: "needs_review", expected: expected, extracted: extracted,
            citation: citation, note: "Could not read a volume from the label statement"
          ) ]
        end

        result = []
        result << match_check(expected, extracted, expected_volume, extracted_volume, citation)
        result << system_check(extracted, extracted_volume, section)
        result << fill_check(extracted_volume, section) if section["required_system"] == "metric"
        result << malt_form_check(extracted, extracted_volume, section) if rules["commodity"] == "malt"
        result.compact
      end

      def missing_check(application, expected, citation)
        embossed = application.container_embossed_info.to_s
        if Parsing::TextNormalizer.normalize(embossed).match?(/contents|\d+\s*(ml|oz|liter|pint|quart|gallon)/)
          FieldCheck.new(
            field: "net_contents", verdict: "pass_with_note", expected: expected, extracted: nil,
            citation: citation,
            note: "Not on the label; the application declares it blown, branded or embossed on the container"
          )
        else
          FieldCheck.new(
            field: "net_contents", verdict: "fail", expected: expected, extracted: nil,
            citation: citation, note: "No net contents statement found on the label"
          )
        end
      end

      def match_check(expected, extracted, expected_volume, extracted_volume, citation)
        if expected_volume.nil?
          FieldCheck.new(
            field: "net_contents", verdict: "needs_review", expected: expected, extracted: extracted,
            citation: citation, note: "Could not read a volume from the application value"
          )
        elsif (expected_volume.milliliters - extracted_volume.milliliters).abs <= FILL_TOLERANCE_ML
          FieldCheck.new(field: "net_contents", verdict: "pass", expected: expected, extracted: extracted,
                         citation: citation, note: nil)
        else
          FieldCheck.new(
            field: "net_contents", verdict: "fail", expected: expected, extracted: extracted,
            citation: citation,
            note: "Label volume (#{format_ml(extracted_volume)}) does not match the application (#{format_ml(expected_volume)})"
          )
        end
      end

      def system_check(extracted, extracted_volume, section)
        required = section["required_system"]
        return nil if extracted_volume.unit_system.to_s == required

        # A metric-required label stated in US measure (or vice versa). The
        # malt BAM allows metric as a supplement only; a lone wrong-system
        # statement fails.
        note =
          if required == "us_customary"
            "Malt beverages must state net contents in American measure (metric may only supplement it)"
          else
            "Net contents must be stated in metric measure"
          end

        FieldCheck.new(
          field: "net_contents_measurement_system", verdict: "fail",
          expected: required, extracted: extracted, citation: section["citation"], note: note
        )
      end

      def fill_check(extracted_volume, section)
        fills = Array(section["standards_of_fill_ml"]).map(&:to_f)
        fills += Array(section["can_standards_of_fill_ml"]).map(&:to_f)
        ml = extracted_volume.milliliters

        return fill_pass(ml, section) if fills.any? { |f| (f - ml).abs <= FILL_TOLERANCE_ML }
        return fill_pass(ml, section) if even_liter_allowed?(ml, section)

        discrepancy = section["discrepancy"]
        additional = Array(discrepancy&.dig("additional_sizes_ml")).map(&:to_f)
        if additional.any? { |f| (f - ml).abs <= FILL_TOLERANCE_ML }
          FieldCheck.new(
            field: "standards_of_fill", verdict: "needs_review", expected: allowed_fills_summary(section),
            extracted: format_raw_ml(ml), citation: section["citation"],
            note: "Not a BAM standard of fill, but permitted under current #{discrepancy['current_regulation']} - agent judgment required"
          )
        else
          FieldCheck.new(
            field: "standards_of_fill", verdict: "fail", expected: allowed_fills_summary(section),
            extracted: format_raw_ml(ml), citation: section["citation"],
            note: "Container size is not an authorized standard of fill"
          )
        end
      end

      def fill_pass(ml, section)
        FieldCheck.new(
          field: "standards_of_fill", verdict: "pass", expected: allowed_fills_summary(section),
          extracted: format_raw_ml(ml), citation: section["citation"], note: nil
        )
      end

      def even_liter_allowed?(ml, section)
        range = section["even_liters_range_ml"]
        return false if range.nil?

        ml >= range["min"] && ml <= range["max"] && (ml % 1000.0).abs <= FILL_TOLERANCE_ML
      end

      def malt_form_check(extracted, extracted_volume, section)
        return nil unless extracted_volume.us_customary?

        buckets = section.dig("form_of_statement", "buckets")
        bucket = find_bucket(buckets, extracted_volume.milliliters)
        return nil if bucket.nil?

        expression = bucket["expression"]
        return nil if form_satisfied?(extracted, expression)

        FieldCheck.new(
          field: "net_contents_form", verdict: "fail", expected: expression, extracted: extracted,
          citation: section.dig("form_of_statement", "citation"),
          note: "For this container size the statement must read in #{expression}"
        )
      end

      def find_bucket(buckets, ml)
        Array(buckets).find do |bucket|
          if bucket["exact_ml"]
            (bucket["exact_ml"].to_f - ml).abs <= FILL_TOLERANCE_ML
          else
            above_min = bucket["min_ml_exclusive"].nil? || ml > bucket["min_ml_exclusive"].to_f + FILL_TOLERANCE_ML
            below_max = bucket["max_ml_exclusive"].nil? || ml < bucket["max_ml_exclusive"].to_f - FILL_TOLERANCE_ML
            above_min && below_max
          end
        end
      end

      def form_satisfied?(extracted, expression)
        text = Parsing::TextNormalizer.normalize(extracted)
        required_units = expression.scan(/pint|quart|gallon|fluid ounces/).uniq
        has_fraction = extracted.match?(%r{\d/\d|0?\.\d+})

        case expression
        when /\A1 (pint|quart|gallon)\z/
          # Exactly one pint/quart/gallon must be stated that way, not in ounces.
          text.include?(Regexp.last_match(1)) && !text.match?(/oz|ounce/)
        when /fractions of a (pint|quart|gallon)/
          larger = Regexp.last_match(1)
          text.match?(/oz|ounce/) || (text.include?(larger) && has_fraction) || text.match?(/pint/)
        else
          required_units.any? { |u| text.include?(u.split.first) }
        end
      end

      def allowed_fills_summary(section)
        fills = Array(section["standards_of_fill_ml"])
        "Authorized sizes: #{fills.map { |f| format_raw_ml(f) }.join(', ')}"
      end

      def format_ml(volume)
        format_raw_ml(volume.milliliters)
      end

      def format_raw_ml(ml)
        ml = ml.to_f
        (ml % 1).zero? ? "#{ml.to_i} mL" : "#{ml.round(1)} mL"
      end
    end
  end
end
