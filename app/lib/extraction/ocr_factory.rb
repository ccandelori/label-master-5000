# frozen_string_literal: true

module Extraction
  # Builds the configured OCR engine. "paddle" (the default) reads via
  # the PaddleOCR sidecar with Tesseract as the automatic fallback when
  # the sidecar is down; "tesseract" runs the local binary alone. The
  # full build wraps the engine in multi-pass enrichment (upscaled and
  # inverted variants merged into the word pool); base_engine is the
  # single-pass form for targeted work like region crops.
  module OcrFactory
    # Bump when anything that changes OCR output changes: engine models,
    # enrichment passes, upscale factor. Stale cache rows simply stop
    # being read.
    CACHE_VERSION = 2

    module_function

    def build
      EnrichedOcr.new(engine: base_engine)
    end

    # Cache key for pools produced by build's engine configuration.
    def cache_key
      "#{Rails.application.config.x.extraction.ocr_engine}-enriched-v#{CACHE_VERSION}"
    end

    def base_engine
      tesseract = OcrClient.build
      return tesseract if Rails.application.config.x.extraction.ocr_engine == "tesseract"

      FallbackOcr.new(primary: PaddleOcrClient.build, fallback: tesseract)
    end
  end
end
