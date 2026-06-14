# frozen_string_literal: true

module Extraction
  # Optional OCR second chances for cases where the base evidence is too
  # weak to support a hard judgment. Escalation is deliberately bounded:
  # it runs only for missing expected fields, only while time remains, and
  # it returns merged OCR evidence rather than compliance findings.
  module OcrEscalation
    ROTATION_DEGREES = [ 90, 270 ].freeze
    CROP_UPSCALE_FACTOR = 2.0
    LOW_WORD_COUNT = 8

    ExpectedField = Data.define(:name, :expected_text, :bbox_hint, :page)
    Result = Data.define(:evidence, :strategies, :duration_ms)
    Strategy = Data.define(:name, :pages, :duration_ms)

    module_function

    def run(artworks:, evidence:, engine:, engine_key:, missing_fields:, deadline_ms:, min_remaining_ms:,
            confidence_threshold:, match_threshold:)
      started = monotonic_ms
      fields = normalize_fields(missing_fields)
      return result(evidence: evidence, strategies: [], started: started) if fields.empty?
      return result(evidence: evidence, strategies: [], started: started) unless weak_enough?(evidence, confidence_threshold)
      return result(evidence: evidence, strategies: [], started: started) unless enough_time?(deadline_ms, min_remaining_ms)

      strategies = []
      strategies.concat(rotation_strategies(
        artworks: artworks, engine: engine, evidence: evidence, fields: fields, deadline_ms: deadline_ms,
        min_remaining_ms: min_remaining_ms, match_threshold: match_threshold
      ))
      strategies.concat(contrast_strategies(
        artworks: artworks, engine: engine, evidence: evidence, deadline_ms: deadline_ms,
        min_remaining_ms: min_remaining_ms
      ))
      strategies.concat(crop_strategies(
        artworks: artworks, engine: engine, evidence: evidence, fields: fields, deadline_ms: deadline_ms,
        min_remaining_ms: min_remaining_ms
      ))

      escalated = merge_evidence(base: evidence, additions: strategies.flat_map(&:pages), engine_key: engine_key)
      log_result(strategies: strategies, duration_ms: monotonic_ms - started)
      result(evidence: escalated, strategies: strategies, started: started)
    end

    def weak_enough?(evidence, confidence_threshold)
      evidence.words.size < LOW_WORD_COUNT || average_confidence(evidence.words).to_f < confidence_threshold
    end

    def merge_evidence(base:, additions:, engine_key:)
      pages_by_number = base.pages.index_by(&:number)
      additions.each do |page|
        existing = pages_by_number[page.number]
        pages_by_number[page.number] = existing ? merge_page(existing, page) : page
      end

      OcrEvidenceStore::Evidence.new(
        pages: pages_by_number.values.sort_by(&:number),
        engine_key: "#{engine_key}+escalated"
      )
    end

    def merge_page(left, right)
      words = (left.words + right.words).uniq do |word|
        [ word.page, word.normalized_text, word.bbox.x, word.bbox.y, word.bbox.width, word.bbox.height ]
      end.sort_by { |word| [ word.bbox.y, word.bbox.x, word.text ] }

      OcrEvidenceStore::Page.new(
        number: left.number,
        width: left.width,
        height: left.height,
        words: words,
        lines: OcrEvidenceStore.build_lines(words, left.number)
      )
    end

    def normalize_fields(fields)
      Array(fields).filter_map do |field|
        if field.is_a?(ExpectedField)
          field
        else
          name = field.respond_to?(:name) ? field.name : field[:name]
          expected_text = field.respond_to?(:expected_text) ? field.expected_text : field[:expected_text]
          bbox_hint = field.respond_to?(:bbox_hint) ? field.bbox_hint : field[:bbox_hint]
          page = field.respond_to?(:page) ? field.page : field[:page]
          next if expected_text.to_s.strip.empty?

          ExpectedField.new(name: name.to_s, expected_text: expected_text.to_s, bbox_hint: bbox_hint, page: page)
        end
      end
    end

    def rotation_strategies(artworks:, engine:, evidence:, fields:, deadline_ms:, min_remaining_ms:, match_threshold:)
      return [] unless fields.any? { |field| warning_field?(field) || likely_rotated_missing?(field, evidence, match_threshold) }
      return [] unless enough_time?(deadline_ms, min_remaining_ms)

      ROTATION_DEGREES.map do |degrees|
        run_async do
          next nil unless enough_time?(deadline_ms, min_remaining_ms)

          timed_strategy("rotate_#{degrees}") do
            transform_image_artworks(artworks: artworks, evidence: evidence) do |artwork, page_number, page, _index|
              rotated = ImageVariants.rotate(artwork.data, degrees: degrees)
              raw_pages = engine.read(data: rotated, content_type: "image/png")
              raw_pages.flat_map do |raw_page|
                [ normalize_raw_page(transform_rotated_page(raw_page, page: page, page_number: page_number, degrees: degrees)) ]
              end
            end
          end
        end
      end.filter_map(&:value)
    end

    def contrast_strategies(artworks:, engine:, evidence:, deadline_ms:, min_remaining_ms:)
      return [] unless average_confidence(evidence.words).to_f < 0.6
      return [] unless enough_time?(deadline_ms, min_remaining_ms)

      [ timed_strategy("contrast") do
        transform_image_artworks(artworks: artworks, evidence: evidence) do |artwork, page_number, _page, _index|
          enhanced = ImageVariants.enhance_contrast(artwork.data)
          engine.read(data: enhanced, content_type: "image/png").map do |raw_page|
            normalize_raw_page(renumber_page(raw_page, page_number))
          end
        end
      end ].compact
    end

    def crop_strategies(artworks:, engine:, evidence:, fields:, deadline_ms:, min_remaining_ms:)
      crop_fields = fields.select { |field| field.bbox_hint.is_a?(Array) && field.bbox_hint.size == 4 && field.page.present? }
      return [] if crop_fields.empty?
      return [] unless enough_time?(deadline_ms, min_remaining_ms)

      [ timed_strategy("crop") do
        crop_fields.flat_map do |field|
          next [] unless enough_time?(deadline_ms, min_remaining_ms)

          crop_for_field(artworks: artworks, engine: engine, evidence: evidence, field: field)
        end
      end ].compact
    end

    def crop_for_field(artworks:, engine:, evidence:, field:)
      artwork = image_artwork_for_page(artworks, field.page)
      page = evidence.page(number: field.page)
      return [] if artwork.nil? || page.nil?

      rect = bounded_rect(field.bbox_hint, page)
      cropped = ImageVariants.crop(artwork.data, rect: rect, upscale_factor: CROP_UPSCALE_FACTOR)
      engine.read(data: cropped, content_type: "image/png").map do |raw_page|
        normalize_raw_page(transform_cropped_page(raw_page, page: page, page_number: field.page, rect: rect))
      end
    rescue OcrError => e
      skip_strategy("crop", e)
      []
    end

    def transform_image_artworks(artworks:, evidence:)
      artworks.each_with_index.flat_map do |artwork, index|
        next [] if artwork.pdf?

        page_number = index + 1
        page = evidence.page(number: page_number)
        next [] if page.nil?

        yield(artwork, page_number, page, index)
      rescue OcrError => e
        skip_strategy("image_variant", e)
        []
      end
    end

    def transform_rotated_page(raw_page, page:, page_number:, degrees:)
      words = raw_page.words.map do |word|
        rotated_word(word: word, page: page, degrees: degrees)
      end
      OcrClient::Page.new(number: page_number, width: page.width, height: page.height, words: words)
    end

    def rotated_word(word:, page:, degrees:)
      case degrees
      when 90
        x = word.y
        y = page.height - word.x - word.width
      when 270
        x = page.width - word.y - word.height
        y = word.x
      else
        raise OcrError, "unsupported OCR rotation #{degrees.inspect}"
      end

      OcrClient.build_word(
        text: word.text,
        x: x,
        y: y,
        width: word.height,
        height: word.width,
        confidence: word.confidence
      )
    end

    def transform_cropped_page(raw_page, page:, page_number:, rect:)
      x_offset, y_offset = rect.first(2)
      words = raw_page.words.map do |word|
        OcrClient.build_word(
          text: word.text,
          x: x_offset + (word.x / CROP_UPSCALE_FACTOR).round,
          y: y_offset + (word.y / CROP_UPSCALE_FACTOR).round,
          width: (word.width / CROP_UPSCALE_FACTOR).round,
          height: (word.height / CROP_UPSCALE_FACTOR).round,
          confidence: word.confidence
        )
      end
      OcrClient::Page.new(number: page_number, width: page.width, height: page.height, words: words)
    end

    def renumber_page(raw_page, page_number)
      OcrClient::Page.new(number: page_number, width: raw_page.width, height: raw_page.height, words: raw_page.words)
    end

    def normalize_raw_page(raw_page)
      OcrEvidenceStore.normalize_page(raw_page)
    end

    def bounded_rect(rect, page)
      x = [[ rect[0].to_i, 0 ].max, page.width - 1 ].min
      y = [[ rect[1].to_i, 0 ].max, page.height - 1 ].min
      right = [[ rect[0].to_i + rect[2].to_i, x + 1 ].max, page.width ].min
      bottom = [[ rect[1].to_i + rect[3].to_i, y + 1 ].max, page.height ].min
      [ x, y, right - x, bottom - y ]
    end

    def image_artwork_for_page(artworks, page_number)
      artwork = artworks[page_number.to_i - 1]
      return nil if artwork.nil? || artwork.pdf?

      artwork
    end

    def likely_rotated_missing?(field, evidence, match_threshold)
      CandidateMatcher.find(
        query: field.expected_text,
        evidence: evidence,
        threshold: match_threshold,
        limit: 1
      ).empty?
    end

    def warning_field?(field)
      field.name.to_s.include?("warning")
    end

    def timed_strategy(name)
      started = monotonic_ms
      pages = yield
      return nil if pages.empty? || pages.all? { |page| page.words.empty? }

      Strategy.new(name: name, pages: pages, duration_ms: monotonic_ms - started)
    end

    def run_async
      Thread.new do
        Rails.application.executor.wrap do
          yield
        rescue OcrError => e
          skip_strategy("parallel_strategy", e)
          nil
        end
      end
    end

    def log_result(strategies:, duration_ms:)
      Rails.logger.info(JSON.generate({
        event: "ocr_escalation_completed",
        strategies: strategies.map(&:name),
        duration_ms: duration_ms
      }))
    end

    def skip_strategy(name, error)
      Rails.logger.warn(JSON.generate({
        event: "ocr_escalation_strategy_skipped",
        strategy: name,
        error: error.message.to_s.first(200)
      }))
    end

    def enough_time?(deadline_ms, min_remaining_ms)
      deadline_ms - monotonic_ms >= min_remaining_ms
    end

    def average_confidence(words)
      values = words.filter_map(&:confidence)
      return 0.0 if values.empty?

      values.sum / values.size.to_f
    end

    def result(evidence:, strategies:, started:)
      Result.new(evidence: evidence, strategies: strategies, duration_ms: monotonic_ms - started)
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
