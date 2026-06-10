# frozen_string_literal: true

module Parsing
  # Extracts the components of an alcohol-content statement from label text.
  # Whether the statement form is permitted for a commodity is rules-engine
  # territory; this module only reads what is there.
  module AlcoholStatement
    Result = Data.define(:percent, :range, :proof, :bottled_at, :raw) do
      def range?
        !range.nil?
      end
    end

    PERCENT = /(\d+(?:\.\d+)?)\s*%/
    RANGE = /(\d+(?:\.\d+)?)\s*%?\s*(?:to|-)\s*(\d+(?:\.\d+)?)\s*%/i
    PROOF = /\(?\s*(\d+(?:\.\d+)?)\s*proof\s*\)?/i
    BOTTLED_AT = /bottled\s+at/i
    ALCOHOL_MARKER = /\b(?:alcohol|alc)\b/i

    module_function

    # "45% ALC./VOL. (90 PROOF)" -> percent 45.0, proof 90.0
    # "9% TO 12% ALC. BY VOL."   -> range [9.0, 12.0]
    # Returns nil when the text contains no recognizable statement.
    def parse(text)
      return nil if text.nil? || text.strip.empty?

      raw = text.strip
      proof = raw[PROOF, 1]&.to_f

      if (m = RANGE.match(raw))
        return Result.new(percent: nil, range: [ m[1].to_f, m[2].to_f ], proof: proof, bottled_at: false, raw: raw)
      end

      percent = raw[PERCENT, 1]&.to_f
      return nil if percent.nil? && proof.nil?

      Result.new(
        percent: percent,
        range: nil,
        proof: proof,
        bottled_at: raw.match?(BOTTLED_AT),
        raw: raw
      )
    end

    # True when the text looks like an alcohol statement at all (used to
    # find the statement among extracted label fields).
    def statement?(text)
      return false if text.nil?

      text.match?(ALCOHOL_MARKER) && (text.match?(PERCENT) || text.match?(PROOF))
    end
  end
end
