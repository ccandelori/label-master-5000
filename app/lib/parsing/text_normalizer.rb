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

      utf8_text(text)
        .unicode_normalize(:nfkd)
        .gsub(/\p{Mn}/, "")
        .downcase
        .gsub(PUNCTUATION, " ")
        .gsub(WHITESPACE, " ")
        .strip
    end

    # "STONE'S THROW" and "Stone's Throw" are equivalent; so are
    # "Côte du Soleil" and "Cote du Soleil", and letter-spaced display
    # type like "V O D K A" against "VODKA" - spacing carries no content.
    def equivalent?(left, right)
      normalized_left = normalize(left).delete(" ")
      return false if normalized_left.empty?

      normalized_left == normalize(right).delete(" ")
    end

    # True when the strings match only after normalization - the
    # pass_with_note case, distinct from an exact match.
    def equivalent_but_not_identical?(left, right)
      equivalent?(left, right) && left.to_s.strip != right.to_s.strip
    end

    def near_equivalent?(left, right)
      left_tokens = normalize(left).split
      right_tokens = normalize(right).split
      return false if left_tokens.empty? || left_tokens.size != right_tokens.size

      left_compact = left_tokens.join
      right_compact = right_tokens.join
      return false if left_compact.length < 6 || right_compact.length < 6

      distance = levenshtein(left_compact, right_compact)
      max_distance = [ 1, (left_compact.length * 0.12).ceil ].max
      distance <= max_distance
    end

    def levenshtein(left, right)
      previous = (0..right.length).to_a

      left.each_char.with_index(1) do |left_char, left_index|
        current = [ left_index ]
        right.each_char.with_index(1) do |right_char, right_index|
          cost = left_char == right_char ? 0 : 1
          current << [
            current[right_index - 1] + 1,
            previous[right_index] + 1,
            previous[right_index - 1] + cost
          ].min
        end
        previous = current
      end

      previous[right.length]
    end

    def utf8_text(text)
      string = text.to_s.dup
      string.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::ASCII_8BIT
      return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: " ")
    end
  end
end
