# frozen_string_literal: true

module Rules
  module Checks
    # Alcohol content: presence requirements, application match, formula
    # tolerance bands, range spreads, proof consistency, and the wine
    # 14 percent tax-class boundary.
    module Alcohol
      MATCH_EPSILON = 0.05

      module_function

      def checks(application, facts, rules)
        section = rules["alcohol_content"]
        citation = section["citation"]
        parsed = Parsing::AlcoholStatement.parse(facts.alcohol_statement)

        result = []
        result << presence_check(application, facts, parsed, rules)
        return result.compact if parsed.nil?

        result << application_match(application, parsed, citation)
        result << formula_tolerance(application, parsed, rules)
        result << range_check(parsed, section) if parsed.range?
        result << proof_check(parsed, section) if rules["commodity"] == "spirits"
        result << boundary_check(application, parsed, section) if rules["commodity"] == "wine"
        result.compact
      end

      def presence_check(application, facts, parsed, rules)
        section = rules["alcohol_content"]
        citation = section["citation"]
        return nil unless parsed.nil?

        case rules["commodity"]
        when "malt"
          FieldCheck.new(
            field: "alcohol_content", verdict: "not_required", expected: stated(application),
            extracted: nil, citation: citation,
            note: "Malt beverage alcohol statements are optional unless state law requires one"
          )
        when "wine"
          if table_or_light_wine?(facts) && (application.alcohol_content.nil? || application.alcohol_content <= 14.0)
            FieldCheck.new(
              field: "alcohol_content", verdict: "not_required", expected: stated(application),
              extracted: nil, citation: citation,
              note: "Optional at or under 14% when designated Table Wine or Light Wine"
            )
          else
            FieldCheck.new(
              field: "alcohol_content", verdict: "fail", expected: stated(application),
              extracted: nil, citation: citation, note: "No alcohol content statement found on the label"
            )
          end
        else
          FieldCheck.new(
            field: "alcohol_content", verdict: "fail", expected: stated(application),
            extracted: nil, citation: citation, note: "No alcohol content statement found on the label"
          )
        end
      end

      def application_match(application, parsed, citation)
        expected = application.alcohol_content&.to_f
        return nil if expected.nil?

        labeled = parsed.percent
        if labeled.nil?
          return FieldCheck.new(
            field: "alcohol_content", verdict: "needs_review", expected: format_pct(expected),
            extracted: parsed.raw, citation: citation,
            note: "Label states a range or proof only; compare against the application manually"
          )
        end

        if (labeled - expected).abs <= MATCH_EPSILON
          FieldCheck.new(field: "alcohol_content", verdict: "pass", expected: format_pct(expected),
                         extracted: parsed.raw, citation: citation, note: nil)
        else
          FieldCheck.new(
            field: "alcohol_content", verdict: "fail", expected: format_pct(expected),
            extracted: parsed.raw, citation: citation,
            note: "Label states #{format_pct(labeled)}; the application states #{format_pct(expected)}"
          )
        end
      end

      # Formula data carries the actual alcohol content; the BAM tolerance
      # band applies between actual and labeled values.
      def formula_tolerance(application, parsed, rules)
        actual = application.actual_alcohol_content&.to_f
        labeled = parsed.percent
        return nil if actual.nil? || labeled.nil?

        section = rules["alcohol_content"]
        deviation = (actual - labeled).round(4)

        case rules["commodity"]
        when "malt"
          band = section["tolerance_percentage_points"].to_f
          tolerance_verdict(deviation.abs <= band, labeled, actual, band, section, symmetric: true)
        when "wine"
          band = labeled <= 14.0 ? section.dig("tolerance_percentage_points", "at_or_under_14").to_f :
                                   section.dig("tolerance_percentage_points", "over_14").to_f
          tolerance_verdict(deviation.abs <= band, labeled, actual, band, section, symmetric: true)
        when "spirits"
          spirits_tolerance(deviation, labeled, actual, section)
        end
      end

      def tolerance_verdict(within, labeled, actual, band, section, symmetric:)
        direction = symmetric ? "plus or minus" : "minus"
        if within
          FieldCheck.new(
            field: "alcohol_content_tolerance", verdict: "pass",
            expected: "Actual #{format_pct(actual)} within #{direction} #{band} points of labeled",
            extracted: format_pct(labeled), citation: section["citation"], note: nil
          )
        else
          FieldCheck.new(
            field: "alcohol_content_tolerance", verdict: "fail",
            expected: "Actual #{format_pct(actual)} within #{direction} #{band} points of labeled",
            extracted: format_pct(labeled), citation: section["citation"],
            note: "Actual alcohol content from the formula is outside the permitted tolerance"
          )
        end
      end

      def spirits_tolerance(deviation, labeled, actual, section)
        loss_band = section.dig("tolerance_percentage_points", "bottling_loss_standard").to_f
        discrepancy = section["discrepancy"]
        current_band = discrepancy["current_tolerance_percentage_points"].to_f

        # The 2007 BAM permits only a bottling loss: actual may fall below
        # the labeled value by the band, never above it.
        if deviation <= 0 && deviation >= -loss_band
          FieldCheck.new(
            field: "alcohol_content_tolerance", verdict: "pass",
            expected: "Actual within #{loss_band} points below labeled (BAM bottling loss)",
            extracted: format_pct(labeled), citation: section["citation"], note: nil
          )
        elsif deviation.abs <= current_band
          FieldCheck.new(
            field: "alcohol_content_tolerance", verdict: "needs_review",
            expected: "Actual within #{loss_band} points below labeled (BAM bottling loss)",
            extracted: format_pct(labeled), citation: section["citation"],
            note: "Outside the BAM allowance but within plus or minus #{current_band} points under current #{discrepancy['current_regulation']} - agent judgment required"
          )
        else
          FieldCheck.new(
            field: "alcohol_content_tolerance", verdict: "fail",
            expected: "Actual within #{loss_band} points below labeled (BAM bottling loss)",
            extracted: format_pct(labeled), citation: section["citation"],
            note: "Actual alcohol content is outside both the BAM allowance and the current-regulation tolerance"
          )
        end
      end

      def range_check(parsed, section)
        spreads = section["range_statements"]
        return nil if spreads.nil?

        low, high = parsed.range
        spread = (high - low).round(4)
        max_spread = high <= 14.0 ? spreads["max_spread_at_or_under_14"].to_f : spreads["max_spread_over_14"].to_f

        if spread <= max_spread
          FieldCheck.new(field: "alcohol_content_range", verdict: "pass",
                         expected: "Range spread of #{max_spread} points or less",
                         extracted: parsed.raw, citation: section["citation"], note: nil)
        else
          FieldCheck.new(field: "alcohol_content_range", verdict: "fail",
                         expected: "Range spread of #{max_spread} points or less",
                         extracted: parsed.raw, citation: section["citation"],
                         note: "Range statement spreads #{spread} percentage points")
        end
      end

      def proof_check(parsed, section)
        return nil if parsed.proof.nil? || parsed.percent.nil?

        expected_proof = (parsed.percent * 2).round(2)
        if (parsed.proof - expected_proof).abs <= 0.01
          FieldCheck.new(field: "proof", verdict: "pass", expected: "#{expected_proof} proof",
                         extracted: "#{parsed.proof} proof", citation: section["citation"], note: nil)
        else
          FieldCheck.new(field: "proof", verdict: "fail", expected: "#{expected_proof} proof",
                         extracted: "#{parsed.proof} proof", citation: section["citation"],
                         note: "Stated proof must equal twice the alcohol content by volume")
        end
      end

      # Within-tolerance values that cross the 14 percent boundary change the
      # wine's tax class and designation; tolerance never excuses that.
      def boundary_check(application, parsed, section)
        boundary = section.dig("tax_class_boundary", "boundary_abv").to_f
        labeled = parsed.percent
        actual = application.actual_alcohol_content&.to_f
        return nil if labeled.nil? || actual.nil?

        labeled_side = labeled <= boundary
        actual_side = actual <= boundary
        return nil if labeled_side == actual_side

        FieldCheck.new(
          field: "alcohol_content_tax_class", verdict: "fail",
          expected: "Labeled and actual content on the same side of #{boundary}%",
          extracted: "labeled #{format_pct(labeled)}, actual #{format_pct(actual)}",
          citation: section.dig("tax_class_boundary", "citation"),
          note: "Crossing the #{boundary}% boundary changes the tax class regardless of tolerance"
        )
      end

      def table_or_light_wine?(facts)
        designation = Parsing::TextNormalizer.normalize(facts.class_type_designation)
        designation.include?("table wine") || designation.include?("light wine")
      end

      def stated(application)
        application.alcohol_content.nil? ? nil : format_pct(application.alcohol_content.to_f)
      end

      def format_pct(value)
        (value % 1).zero? ? "#{value.to_i}%" : "#{value}%"
      end
    end
  end
end
