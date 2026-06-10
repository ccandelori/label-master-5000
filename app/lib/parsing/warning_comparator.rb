# frozen_string_literal: true

module Parsing
  # Compares an extracted health-warning statement against the statutory
  # text. The words must match exactly (27 CFR 16.21); the "GOVERNMENT
  # WARNING" prefix must be in capital letters (27 CFR 16.22). Bold type and
  # paragraph continuity are visual attributes assessed by the extractor,
  # not here.
  module WarningComparator
    PREFIX = "GOVERNMENT WARNING:"

    Result = Data.define(:text_matches, :prefix_all_caps, :missing_words, :extra_words)

    module_function

    def compare(extracted, statutory)
      return Result.new(text_matches: false, prefix_all_caps: false, missing_words: [], extra_words: []) if blank?(extracted)

      extracted_words = words(extracted)
      statutory_words = words(statutory)

      Result.new(
        text_matches: extracted_words == statutory_words,
        prefix_all_caps: prefix_all_caps?(extracted),
        missing_words: statutory_words - extracted_words,
        extra_words: extracted_words - statutory_words
      )
    end

    # Case-insensitive word sequence: the statute mandates the words, while
    # capitalization is only mandated for the prefix (whole-statement caps,
    # as on many real labels, is acceptable).
    def words(text)
      text.to_s.downcase.gsub(/[“”]/, '"').gsub(/[‘’]/, "'").scan(/[a-z0-9']+|\(\d+\)/)
    end

    def prefix_all_caps?(extracted)
      extracted.to_s.strip.start_with?(PREFIX)
    end

    def blank?(text)
      text.nil? || text.strip.empty?
    end
  end
end
