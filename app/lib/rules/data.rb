# frozen_string_literal: true

module Rules
  # Loads and validates the BAM-derived rule data in config/label_rules.
  # Validation runs at boot (config/initializers/label_rules.rb) so malformed
  # rule data fails fast instead of producing silent wrong verdicts.
  module Data
    class InvalidRuleData < StandardError; end

    COMMODITIES = %w[malt wine spirits].freeze

    REQUIRED_COMMODITY_SECTIONS = %w[
      commodity alcohol_content net_contents designations
      name_and_address country_of_origin disclosures
    ].freeze

    module_function

    def for(commodity)
      raise InvalidRuleData, "unknown commodity: #{commodity.inspect}" unless COMMODITIES.include?(commodity.to_s)

      all.fetch(commodity.to_s)
    end

    def shared
      all.fetch("shared")
    end

    def statutory_warning_text
      shared.dig("health_warning", "statutory_text")
    end

    def all
      @all ||= load_and_validate!
    end

    def reload!
      @all = nil
      all
    end

    def load_and_validate!
      data = {}
      data["shared"] = load_file("shared")
      COMMODITIES.each { |c| data[c] = load_file(c) }

      validate_shared!(data["shared"])
      COMMODITIES.each { |c| validate_commodity!(c, data[c]) }
      data.freeze
    end

    def load_file(name)
      path = Rails.root.join("config/label_rules/#{name}.yml")
      raise InvalidRuleData, "missing rule file: #{path}" unless File.exist?(path)

      YAML.load_file(path)
    rescue Psych::SyntaxError => e
      raise InvalidRuleData, "#{name}.yml does not parse: #{e.message}"
    end

    def validate_shared!(shared)
      warning = shared["health_warning"]
      fail!("shared", "health_warning section missing") if warning.nil?
      fail!("shared", "health_warning.statutory_text missing") if warning["statutory_text"].to_s.strip.empty?
      fail!("shared", "health_warning.citation missing") if warning["citation"].to_s.strip.empty?

      unless warning["statutory_text"].start_with?("GOVERNMENT WARNING:")
        fail!("shared", "statutory_text must begin with the GOVERNMENT WARNING: prefix")
      end
    end

    def validate_commodity!(name, rules)
      REQUIRED_COMMODITY_SECTIONS.each do |section|
        fail!(name, "missing required section: #{section}") unless rules.key?(section)
      end

      fail!(name, "commodity key mismatch") unless rules["commodity"] == name

      validate_citations!(name, rules)
      validate_tolerances!(name, rules["alcohol_content"])
      validate_net_contents!(name, rules["net_contents"])
      validate_designations!(name, rules["designations"])
      validate_disclosures!(name, rules["disclosures"])
    end

    def validate_citations!(name, rules)
      %w[alcohol_content net_contents designations name_and_address country_of_origin].each do |section|
        citation = rules.dig(section, "citation")
        fail!(name, "#{section}.citation missing") if citation.to_s.strip.empty?
      end
    end

    def validate_tolerances!(name, abv)
      tolerance = abv["tolerance_percentage_points"]
      fail!(name, "alcohol_content.tolerance_percentage_points missing") if tolerance.nil?

      numbers =
        case tolerance
        when Numeric then [ tolerance ]
        when Hash then tolerance.values.select { |v| v.is_a?(Numeric) }
        else fail!(name, "tolerance_percentage_points must be a number or hash of numbers")
        end

      fail!(name, "tolerance values must be positive numbers") if numbers.empty? || numbers.any? { |v| v <= 0 }
    end

    def validate_net_contents!(name, net)
      system = net["required_system"]
      unless %w[metric us_customary].include?(system)
        fail!(name, "net_contents.required_system must be metric or us_customary")
      end

      fills = net["standards_of_fill_ml"]
      if system == "metric"
        fail!(name, "metric commodities need standards_of_fill_ml") unless fills.is_a?(Array) && fills.any?
        fail!(name, "standards_of_fill_ml must be positive numbers") if fills.any? { |v| !v.is_a?(Numeric) || v <= 0 }
      end
    end

    def validate_designations!(name, designations)
      entries = designations["entries"]
      fail!(name, "designations.entries must be a non-empty list") unless entries.is_a?(Array) && entries.any?

      entries.each_with_index do |entry, index|
        names = entry["names"]
        fail!(name, "designations.entries[#{index}].names must be non-empty") unless names.is_a?(Array) && names.any?
        fail!(name, "designations.entries[#{index}].kind missing") if entry["kind"].to_s.strip.empty?
        unless [ true, false, "conditional" ].include?(entry["sufficient"])
          fail!(name, "designations.entries[#{index}].sufficient must be true, false, or conditional")
        end
      end
    end

    def validate_disclosures!(name, disclosures)
      fail!(name, "disclosures must be a list") unless disclosures.is_a?(Array)

      disclosures.each_with_index do |d, index|
        fail!(name, "disclosures[#{index}].key missing") if d["key"].to_s.strip.empty?
        fail!(name, "disclosures[#{index}].citation missing") if d["citation"].to_s.strip.empty?
        unless d["required_text"].is_a?(Array)
          fail!(name, "disclosures[#{index}].required_text must be a list")
        end
        if d["required_text"].empty? && d["pattern_allowed"].to_s.strip.empty?
          fail!(name, "disclosures[#{index}] needs required_text entries or a pattern_allowed")
        end
      end
    end

    def fail!(file, message)
      raise InvalidRuleData, "label_rules/#{file}.yml: #{message}"
    end
  end
end
