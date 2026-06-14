# frozen_string_literal: true

require "set"

module Extraction
  # Fuzzy, evidence-grounded search over normalized OCR evidence. This is
  # the deterministic "find the application value on the label" layer:
  # it returns ranked candidates with page, bbox, confidence, and match
  # score, leaving compliance judgment to rules and VLM adjudication.
  module CandidateMatcher
    SIZE_SLACK = 0.35
    SUBSTRING_MIN_LENGTH = 3
    SUBSTRING_MIN_RATIO = 0.2
    LONG_TEXT_MIN_LENGTH = 120
    LONG_TEXT_MIN_TOKENS = 8
    LONG_TEXT_TOKEN_RECALL_FLOOR = 0.25
    TOKEN_SCORE_CEILING = 0.94

    Match = Data.define(:text, :normalized_text, :confidence, :bbox, :page, :match_score) do
      def to_h
        {
          text: text,
          normalized_text: normalized_text,
          confidence: confidence,
          bbox: bbox.to_h,
          page: page,
          match_score: match_score
        }
      end
    end

    Target = Data.define(:normalized_text, :compact_text, :tokens, :token_set, :long_text)
    Candidate = Data.define(:text, :items, :page, :normalized_text, :compact_text, :tokens, :token_set)

    module_function

    def find(query:, evidence:, threshold:, limit:)
      target = build_target(query)
      return [] if target.compact_text.empty?

      matches = evidence.pages.flat_map do |page|
        candidates_for_page(page: page, target: target).filter_map do |candidate|
          score = score(candidate, target)
          next if score < threshold

          build_match(candidate: candidate, score: score)
        end
      end

      dedupe(matches)
        .sort_by { |match| [ -match.match_score, match.page, match.bbox.y, match.bbox.x ] }
        .first(limit)
    end

    def candidates_for_page(page:, target:)
      [
        sequence_candidates(items: page.words, page_number: page.number, target: target),
        sequence_candidates(items: page.words.reverse, page_number: page.number, target: target),
        sequence_candidates(items: page.lines, page_number: page.number, target: target)
      ].flatten
    end

    def sequence_candidates(items:, page_number:, target:)
      target_length = target.compact_text.length
      min_length = (target_length * (1 - SIZE_SLACK)).floor
      max_length = (target_length * (1 + SIZE_SLACK)).ceil
      normalized_items = items.map { |item| normalized_item_text(item) }
      compact_items = normalized_items.map { |text| text.delete(" ") }
      token_items = normalized_items.map(&:split)
      candidates = []

      (0...items.size).each do |start|
        compact_text = +""
        token_set = Set.new

        (start...items.size).each do |stop|
          compact_text << compact_items[stop]
          token_set.merge(token_items[stop])

          substring = substring_candidate?(compact_text, target.compact_text)
          compact_length = compact_text.length
          break if compact_length > max_length && !substring
          next if compact_length < min_length && !substring
          next if insufficient_token_overlap?(token_set, target, substring)

          candidates << build_candidate(
            items: items[start..stop],
            page_number: page_number
          )
        end
      end

      candidates
    end

    def build_target(text)
      normalized_text = Parsing::TextNormalizer.normalize(text)
      compact_text = normalized_text.delete(" ")
      tokens = normalized_text.split
      Target.new(
        normalized_text: normalized_text,
        compact_text: compact_text,
        tokens: tokens,
        token_set: tokens.to_set,
        long_text: long_text?(compact_text, tokens)
      )
    end

    def build_candidate(items:, page_number:)
      text = join_text(items)
      normalized_text = Parsing::TextNormalizer.normalize(text)
      tokens = normalized_text.split
      Candidate.new(
        text: text,
        items: items,
        page: page_number,
        normalized_text: normalized_text,
        compact_text: normalized_text.delete(" "),
        tokens: tokens,
        token_set: tokens.to_set
      )
    end

    def build_match(candidate:, score:)
      bbox = candidate.items.map(&:bbox).reduce(&:union)
      Match.new(
        text: candidate.text,
        normalized_text: candidate.normalized_text,
        confidence: average_confidence(candidate.items),
        bbox: bbox,
        page: candidate.page,
        match_score: score.round(4)
      )
    end

    def score(candidate, target)
      return 1.0 if candidate.compact_text == target.compact_text
      return 0.95 if substring_candidate?(candidate.compact_text, target.compact_text)
      return 0.0 if candidate.compact_text.empty?
      return token_similarity(candidate.token_set, target.token_set) if token_scoring?(candidate, target)

      distance = Parsing::TextNormalizer.levenshtein(target.compact_text, candidate.compact_text)
      1.0 - (distance.to_f / [ target.compact_text.length, candidate.compact_text.length ].max)
    end

    def substring_candidate?(candidate, target)
      return false if target.length < SUBSTRING_MIN_LENGTH
      return false unless candidate.include?(target)

      target.length.fdiv(candidate.length) >= SUBSTRING_MIN_RATIO
    end

    def token_scoring?(candidate, target)
      return true if target.long_text

      long_text?(candidate.compact_text, candidate.tokens)
    end

    def insufficient_token_overlap?(candidate_token_set, target, substring)
      return false if substring
      return token_recall(candidate_token_set, target.token_set) < LONG_TEXT_TOKEN_RECALL_FLOOR if target.long_text
      return false if target.tokens.size < 2

      (candidate_token_set & target.token_set).empty?
    end

    def long_text?(compact_text, tokens)
      compact_text.length >= LONG_TEXT_MIN_LENGTH || tokens.size >= LONG_TEXT_MIN_TOKENS
    end

    def token_recall(candidate_token_set, target_token_set)
      return 0.0 if candidate_token_set.empty? || target_token_set.empty?

      (candidate_token_set & target_token_set).size.fdiv(target_token_set.size)
    end

    def token_similarity(candidate_token_set, target_token_set)
      return 0.0 if candidate_token_set.empty? || target_token_set.empty?

      overlap = (candidate_token_set & target_token_set).size
      precision = overlap.fdiv(candidate_token_set.size)
      recall = overlap.fdiv(target_token_set.size)
      return 0.0 if precision.zero? || recall.zero?

      [ (2.0 * precision * recall) / (precision + recall), TOKEN_SCORE_CEILING ].min
    end

    def normalized_item_text(item)
      return item.normalized_text if item.respond_to?(:normalized_text)

      Parsing::TextNormalizer.normalize(item.text)
    end

    def join_text(items)
      items.map(&:text).join(" ").gsub(/-\s+/, "")
    end

    def average_confidence(items)
      values = items.filter_map(&:confidence)
      return nil if values.empty?

      values.sum / values.size.to_f
    end

    def dedupe(matches)
      seen = Set.new
      matches.select do |match|
        key = [ match.page, match.text, match.bbox.x, match.bbox.y, match.bbox.width, match.bbox.height ]
        seen.add?(key)
      end
    end
  end
end
