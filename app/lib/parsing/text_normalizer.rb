# frozen_string_literal: true

module Parsing
  # Deterministic normalization for fuzzy field matching. Differences that
  # survive normalization are judgment calls for the model/agent, not this
  # module: it only erases casing, punctuation, diacritics, and whitespace.
  module TextNormalizer
    PUNCTUATION = /[[:punct:]]/
    WHITESPACE = /\s+/

    module_function

    def normalize(text)
      return "" if text.nil?

      text.unicode_normalize(:nfkd)
          .gsub(/\p{Mn}/, "")
          .downcase
          .gsub(PUNCTUATION, " ")
          .gsub(WHITESPACE, " ")
          .strip
    end

    # "STONE'S THROW" and "Stone's Throw" are equivalent; so are
    # "Côte du Soleil" and "Cote du Soleil".
    def equivalent?(left, right)
      normalized_left = normalize(left)
      return false if normalized_left.empty?

      normalized_left == normalize(right)
    end

    # True when the strings match only after normalization - the
    # pass_with_note case, distinct from an exact match.
    def equivalent_but_not_identical?(left, right)
      equivalent?(left, right) && left.to_s.strip != right.to_s.strip
    end
  end
end
