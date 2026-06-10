# frozen_string_literal: true

module Parsing
  # Parses net-contents statements from applications and label text into
  # ParsedVolume values. Returns nil for unparseable input - whether that
  # is acceptable is a rules-engine decision, not a parsing one.
  module NetContents
    ML_PER_FL_OZ = 29.5735295625
    ML_PER_PINT = ML_PER_FL_OZ * 16
    ML_PER_QUART = ML_PER_FL_OZ * 32
    ML_PER_GALLON = ML_PER_FL_OZ * 128

    METRIC_UNITS = {
      /\A(?:ml|mls|milliliters?)\z/i => 1.0,
      /\A(?:cl|centiliters?)\z/i => 10.0,
      /\A(?:l|liters?|litres?)\z/i => 1000.0
    }.freeze

    US_UNITS = {
      /\A(?:fl\.?\s*oz\.?|fluid\s+ounces?|ounces?|oz\.?)\z/i => ML_PER_FL_OZ,
      /\A(?:pts?\.?|pints?)\z/i => ML_PER_PINT,
      /\A(?:qts?\.?|quarts?)\z/i => ML_PER_QUART,
      /\A(?:gals?\.?|gallons?)\z/i => ML_PER_GALLON
    }.freeze

    QUANTITY = %r{
      (?:(?<whole>\d+(?:\.\d+)?)(?:\s+(?<frac_num>\d+)/(?<frac_den>\d+))?)
      |
      (?:(?<num>\d+)/(?<den>\d+))
    }x

    SEGMENT = /#{QUANTITY}\s*(?<unit>[a-zA-Z][a-zA-Z. ]*?)(?=\s*(?:,|\band\b|\d)|\s*\z)/

    module_function

    # "750 mL" -> metric 750.0; "1 pint, 4 fl oz" -> us_customary sum;
    # "4/5 quart" and "1 1/4 gallons" handle fractional American forms.
    def parse(text)
      return nil if text.nil? || text.strip.empty?

      segments = scan_segments(text.strip)
      return nil if segments.empty?

      total_ml = 0.0
      systems = []

      segments.each do |quantity, unit_text|
        factor, system = unit_factor(unit_text)
        return nil if factor.nil?

        total_ml += quantity * factor
        systems << system
      end

      # Mixed-system statements ("1 pint 500 ml") are not a thing on labels;
      # treat them as unparseable rather than guess.
      return nil if systems.uniq.size > 1

      ParsedVolume.new(milliliters: total_ml.round(4), unit_system: systems.first, raw: text)
    end

    def scan_segments(text)
      result = []
      text.scan(SEGMENT) do
        m = Regexp.last_match
        result << [ quantity_from(m), m[:unit].strip ]
      end
      result
    end

    def quantity_from(match)
      if match[:num] && match[:den]
        match[:num].to_f / match[:den].to_f
      else
        whole = match[:whole].to_f
        if match[:frac_num] && match[:frac_den]
          whole + (match[:frac_num].to_f / match[:frac_den].to_f)
        else
          whole
        end
      end
    end

    def unit_factor(unit_text)
      METRIC_UNITS.each { |pattern, factor| return [ factor, :metric ] if unit_text.match?(pattern) }
      US_UNITS.each { |pattern, factor| return [ factor, :us_customary ] if unit_text.match?(pattern) }
      [ nil, nil ]
    end
  end
end
