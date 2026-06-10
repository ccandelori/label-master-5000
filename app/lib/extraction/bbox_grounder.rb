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
    # Candidate windows range over the target's token count +/- this
    # fraction, absorbing OCR word splits and merges.
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

      matched_words = best_match(target_tokens, page.words, threshold)
      return field.merge("bbox_source" => "model") if matched_words.nil?

      field.merge(
        "bbox" => union_bbox(matched_words),
        "bbox_basis" => [ page.width, page.height ],
        "bbox_source" => "ocr"
      )
    end

    # Slides windows of near-target size over the OCR word sequence and
    # returns the words of the best-scoring window at or above threshold,
    # or nil. Words that normalize to nothing (stray punctuation) are
    # excluded from the sequence so they neither pad nor split windows.
    def best_match(target_tokens, words, threshold)
      indexed = words.filter_map do |word|
        normalized = normalize(word.text)
        [ word, normalized ] unless normalized.empty?
      end
      return nil if indexed.empty?

      target = target_tokens.join(" ")
      target_tally = target_tokens.tally
      size = target_tokens.size
      min_size = [ 1, (size * (1 - SIZE_SLACK)).floor ].max
      max_size = [ (size * (1 + SIZE_SLACK)).ceil, indexed.size ].min

      best_words = nil
      best_score = -1.0

      (min_size..max_size).each do |window_size|
        (0..indexed.size - window_size).each do |start|
          window = indexed[start, window_size]
          window_tokens = window.flat_map { |_, normalized| normalized.split(" ") }
          if size > PREFILTER_MIN_TOKENS && overlap(window_tokens, target_tally) < OVERLAP_PREFILTER
            next
          end

          candidate = window_tokens.join(" ")
          # Length difference alone lower-bounds the edit distance, so a
          # window too different in length cannot reach the threshold.
          next if length_bound(target, candidate) < threshold

          score = similarity(target, candidate)
          if score > best_score
            best_score = score
            best_words = window.map { |word, _| word }
          end
        end
      end

      best_score >= threshold ? best_words : nil
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

    # The best similarity two strings of these lengths could achieve.
    def length_bound(a, b)
      max_length = [ a.length, b.length ].max
      return 1.0 if max_length.zero?

      1.0 - (a.length - b.length).abs.fdiv(max_length)
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
