# frozen_string_literal: true

module Extraction
  # Re-anchors the model's estimated bounding boxes to OCR word geometry.
  # For each located field, the field text is fuzzy-matched against the
  # page's OCR word sequence; on a hit the bbox becomes the pixel-exact
  # union of the matched words (with bbox_basis carrying that page's
  # raster dimensions and bbox_source "ocr"). On a miss the model's box
  # is kept untouched and marked bbox_source "model". Pure and total,
  # like FactsMapper: never raises on missing structure, never mutates
  # its inputs.
  module BboxGrounder
    # Windows whose token overlap with the target falls below this skip
    # the (comparatively expensive) edit-distance scoring. Only applied to
    # targets longer than PREFILTER_MIN_TOKENS: short fields are cheap to
    # score directly, and exact-token overlap is unreliable when most of a
    # short window's words carry OCR character errors.
    OVERLAP_PREFILTER = 0.5
    PREFILTER_MIN_TOKENS = 8

    # Recognition sometimes fuses neighbors into one token ("LOVES IPA"
    # read as "LOVE8IPA"). When no window matches, a target found verbatim
    # inside a longer token still counts - if it is long enough, and a
    # substantial enough part of its host, to not be coincidence ("ipa"
    # inside "participate" must not match).
    SUBSTRING_MIN_LENGTH = 3
    SUBSTRING_MIN_RATIO = 0.3
    # Candidate windows range over the target's character length +/- this
    # fraction, absorbing OCR word splits, merges, and stray marks.
    SIZE_SLACK = 0.3

    module_function

    # payload: the raw extraction JSON; pages: Array of OcrClient::Page;
    # threshold: minimum similarity (0..1) for a match to replace a box.
    def ground(payload:, pages:, threshold:)
      pages_by_number = pages.to_h { |page| [ page.number, page ] }
      grounded = payload.dup

      if payload["fields"].is_a?(Hash)
        grounded["fields"] = payload["fields"].transform_values do |field|
          ground_field(field, pages_by_number, threshold)
        end
      end

      %w[varietals disclosures].each do |key|
        next unless payload[key].is_a?(Array)

        grounded[key] = payload[key].map { |field| ground_field(field, pages_by_number, threshold) }
      end

      grounded
    end

    def ground_field(field, pages_by_number, threshold)
      return field unless field.is_a?(Hash)

      target_tokens = tokenize(field["text"])
      page = pages_by_number[field["page"] || 1]
      return field.merge("bbox_source" => "model") if target_tokens.empty? || page.nil?

      matched = best_match(target_tokens, page.words, threshold)
      return field.merge("bbox_source" => "model") if matched.nil?

      field.merge(
        "bbox" => union_bbox(matched.map(&:first).uniq),
        "bbox_basis" => [ page.width, page.height ],
        "bbox_source" => "ocr"
      )
    end

    # Slides windows over the OCR word sequence and returns the words of
    # the best-scoring window at or above threshold, or nil. Windows are
    # sized by character length, not word count, and similarity compares
    # space-stripped strings: letter-spaced display type ("D R A U G H T")
    # arrives from OCR as one word per letter and must still match its
    # target. Words that normalize to nothing (stray punctuation) are
    # excluded from the sequence so they neither pad nor split windows.
    def best_match(target_tokens, words, threshold)
      # One OCR entry may carry several tokens (line-level engines emit
      # "TEDDY LOVES IPA" as one entry); each token enters the sequence
      # separately, sharing its parent's box, so a target inside a longer
      # line is still matchable. The union then covers the parent line.
      indexed = words.flat_map do |word|
        normalize(word.text).split(" ").map { |token| [ word, token ] }
      end
      return nil if indexed.empty?

      target_compact = target_tokens.join
      min_length = (target_compact.length * (1 - SIZE_SLACK)).floor
      max_length = (target_compact.length * (1 + SIZE_SLACK)).ceil
      target_tally = target_tokens.tally
      prefilter = target_tokens.size > PREFILTER_MIN_TOKENS

      best_pairs = nil
      best_score = -1.0

      (0...indexed.size).each do |start|
        length = 0
        (start...indexed.size).each do |stop|
          length += indexed[stop].last.length
          break if length > max_length
          next if length < min_length

          window = indexed[start..stop]
          next if prefilter && overlap(window.map(&:last), target_tally) < OVERLAP_PREFILTER

          score = similarity(target_compact, window.map(&:last).join)
          if score > best_score
            best_score = score
            best_pairs = window
          end
        end
      end

      return best_pairs if best_score >= threshold

      fused_token_match(indexed, target_compact)
    end

    # The fallback for fused recognition: the target appearing verbatim
    # inside a longer token. The pair carries the target itself as the
    # token, so a reconciled field reads as the declared name rather than
    # the fused noise around it.
    def fused_token_match(indexed, target_compact)
      return nil if target_compact.length < SUBSTRING_MIN_LENGTH

      host = indexed.select do |_, token|
        token.length > target_compact.length &&
          token.include?(target_compact) &&
          target_compact.length.fdiv(token.length) >= SUBSTRING_MIN_RATIO
      end.min_by { |_, token| token.length }

      host && [ [ host.first, target_compact ] ]
    end

    # Fraction of the target's tokens present in the window (multiset).
    def overlap(window_tokens, target_tally)
      remaining = target_tally.dup
      matched = window_tokens.count do |token|
        next false unless remaining.fetch(token, 0).positive?

        remaining[token] -= 1
        true
      end
      total = target_tally.each_value.sum
      total.zero? ? 0.0 : matched.fdiv(total)
    end

    def tokenize(text)
      normalize(text).split(" ")
    end

    # Case-folds and strips everything except letters, digits, and percent
    # signs; both the field text and the OCR words pass through this, so
    # punctuation and styling differences cannot break a match.
    def normalize(text)
      text.to_s.upcase.gsub(/[^A-Z0-9%]+/, " ").strip
    end

    # Normalized Levenshtein similarity in 0..1.
    def similarity(a, b)
      return 1.0 if a == b
      return 0.0 if a.empty? || b.empty?

      1.0 - levenshtein(a, b).fdiv([ a.length, b.length ].max)
    end

    def levenshtein(a, b)
      previous = (0..b.length).to_a

      a.each_char.with_index(1) do |char_a, i|
        current = [ i ]
        b.each_char.with_index(1) do |char_b, j|
          cost = char_a == char_b ? 0 : 1
          current << [ current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost ].min
        end
        previous = current
      end

      previous[b.length]
    end

    def union_bbox(words)
      x = words.map(&:x).min
      y = words.map(&:y).min
      right = words.map { |word| word.x + word.width }.max
      bottom = words.map { |word| word.y + word.height }.max
      [ x, y, right - x, bottom - y ]
    end
  end
end
