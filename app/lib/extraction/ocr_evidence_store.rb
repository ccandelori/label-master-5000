# frozen_string_literal: true

module Extraction
  # Normalized OCR evidence over the existing page pool/cache. OCR engines
  # can disagree about whether an entry is a word or a text line; this
  # layer makes that output safe and queryable before candidate matching,
  # reconciliation, or rules see it.
  module OcrEvidenceStore
    LINE_CENTER_TOLERANCE = 0.7

    Bbox = Data.define(:x, :y, :width, :height) do
      def right
        x + width
      end

      def bottom
        y + height
      end

      def intersects?(other)
        right > other.x && other.right > x && bottom > other.y && other.bottom > y
      end

      def union(other)
        left = [ x, other.x ].min
        top = [ y, other.y ].min
        Bbox.new(
          x: left,
          y: top,
          width: [ right, other.right ].max - left,
          height: [ bottom, other.bottom ].max - top
        )
      end

      def to_h
        { x: x, y: y, width: width, height: height }
      end
    end

    Word = Data.define(:text, :normalized_text, :confidence, :bbox, :page)
    Line = Data.define(:text, :normalized_text, :confidence, :bbox, :page, :words)

    Page = Data.define(:number, :width, :height, :words, :lines) do
      def text
        lines.map(&:text).join("\n")
      end

      def words_in_region(bbox:)
        words.select { |word| word.bbox.intersects?(bbox) }
      end

      def lines_in_region(bbox:)
        lines.select { |line| line.bbox.intersects?(bbox) }
      end
    end

    Evidence = Data.define(:pages, :engine_key) do
      def words
        pages.flat_map(&:words)
      end

      def lines
        pages.flat_map(&:lines)
      end

      def text
        pages.map(&:text).join("\n\n")
      end

      def page(number:)
        pages.find { |candidate| candidate.number == number }
      end

      def words_in_region(page:, bbox:)
        selected = self.page(number: page)
        selected ? selected.words_in_region(bbox: bbox) : []
      end

      def lines_in_region(page:, bbox:)
        selected = self.page(number: page)
        selected ? selected.lines_in_region(bbox: bbox) : []
      end
    end

    module_function

    def read(artworks:, engine:, engine_key:)
      raw_pages = OcrPagePool.read(artworks: artworks, engine: engine, engine_key: engine_key)
      Evidence.new(
        pages: raw_pages.map { |page| normalize_page(page) },
        engine_key: engine_key
      )
    end

    def normalize_page(raw_page)
      words = Array(raw_page.words).filter_map { |word| normalize_word(word, raw_page.number) }
      words = words.sort_by { |word| [ word.bbox.y, word.bbox.x ] }
      Page.new(
        number: raw_page.number,
        width: raw_page.width.to_i,
        height: raw_page.height.to_i,
        words: words,
        lines: build_lines(words, raw_page.number)
      )
    end

    def normalize_word(raw_word, page_number)
      text = normalize_text(raw_word.text)
      return nil if text.empty?

      bbox = bbox_for(raw_word)
      return nil if bbox.nil?

      Word.new(
        text: text,
        normalized_text: Parsing::TextNormalizer.normalize(text),
        confidence: confidence_for(raw_word),
        bbox: bbox,
        page: page_number
      )
    end

    def bbox_for(raw_word)
      x = integer_or_nil(raw_word.x)
      y = integer_or_nil(raw_word.y)
      width = integer_or_nil(raw_word.width)
      height = integer_or_nil(raw_word.height)
      return nil if [ x, y, width, height ].any?(&:nil?)
      return nil unless width.positive? && height.positive?

      Bbox.new(x: x, y: y, width: width, height: height)
    end

    def build_lines(words, page_number)
      grouped_words(words).map do |line_words|
        ordered = line_words.sort_by { |word| word.bbox.x }
        text = ordered.map(&:text).join(" ")
        Line.new(
          text: text,
          normalized_text: Parsing::TextNormalizer.normalize(text),
          confidence: average_confidence(ordered),
          bbox: ordered.map(&:bbox).reduce(&:union),
          page: page_number,
          words: ordered
        )
      end
    end

    def grouped_words(words)
      groups = []
      boxes = []

      words.each do |word|
        current_box = boxes.last
        if current_box && same_line_box?(current_box, word)
          groups.last << word
          boxes[-1] = current_box.union(word.bbox)
        else
          groups << [ word ]
          boxes << word.bbox
        end
      end

      groups
    end

    def same_line?(line_words, word)
      line_box = line_words.map(&:bbox).reduce(&:union)
      same_line_box?(line_box, word)
    end

    def same_line_box?(line_box, word)
      center_delta = ((line_box.y + (line_box.height / 2.0)) - (word.bbox.y + (word.bbox.height / 2.0))).abs
      tolerance = [ line_box.height, word.bbox.height ].max * LINE_CENTER_TOLERANCE
      center_delta <= tolerance
    end

    def normalize_text(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
           .gsub(/[[:space:]]+/, " ")
           .strip
    end

    def confidence_for(raw_word)
      return nil unless raw_word.respond_to?(:confidence)

      value = Float(raw_word.confidence, exception: false)
      return nil if value.nil? || value.negative?

      value
    end

    def average_confidence(words)
      values = words.filter_map(&:confidence)
      return nil if values.empty?

      values.sum / values.size.to_f
    end

    def integer_or_nil(value)
      Integer(value, exception: false)
    end
  end
end
