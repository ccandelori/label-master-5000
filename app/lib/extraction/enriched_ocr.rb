# frozen_string_literal: true

module Extraction
  # Multi-pass OCR over a base engine: the original image plus an upscaled
  # pass (recovers fine print) and a grayscale-inverted pass (recovers
  # light-on-dark type), with every variant's word geometry scaled back to
  # the original pixel basis and merged into one pool. The matcher takes
  # the best window wherever it appears, and duplicate detections at the
  # same coordinates are harmless to box unions.
  #
  # The base pass is mandatory; variant passes are best-effort (a missing
  # imagemagick or a variant the engine chokes on logs and is skipped).
  # PDFs get the base pass only - their pages are already rasterized at a
  # chosen DPI upstream.
  class EnrichedOcr
    UPSCALE_FACTOR = 2.0

    def initialize(engine:)
      @engine = engine
    end

    def read(data:, content_type:)
      base = @engine.read(data: data, content_type: content_type)
      return base if content_type == OcrClient::PDF_CONTENT_TYPE

      page = base.first
      extras = variant_words(data)
      return base if extras.empty?

      [ OcrClient::Page.new(
        number: page.number, width: page.width, height: page.height,
        words: page.words + extras
      ) ]
    end

    private

    def variant_words(data)
      upscaled(data) + inverted(data)
    end

    def upscaled(data)
      pages = @engine.read(data: ImageVariants.upscale(data, factor: UPSCALE_FACTOR), content_type: "image/png")
      pages.flat_map(&:words).map { |w| scale_word(w, 1.0 / UPSCALE_FACTOR) }
    rescue OcrError => e
      skip_variant("upscale", e)
    end

    def inverted(data)
      pages = @engine.read(data: ImageVariants.invert(data), content_type: "image/png")
      pages.flat_map(&:words)
    rescue OcrError => e
      skip_variant("invert", e)
    end

    def scale_word(word, factor)
      OcrClient::Word.new(
        text: word.text,
        x: (word.x * factor).round, y: (word.y * factor).round,
        width: (word.width * factor).round, height: (word.height * factor).round
      )
    end

    def skip_variant(name, error)
      Rails.logger.warn(JSON.generate({
        event: "ocr_variant_skipped", variant: name, error: error.message.to_s.first(200)
      }))
      []
    end
  end
end
