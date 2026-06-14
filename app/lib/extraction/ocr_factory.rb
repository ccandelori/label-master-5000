# frozen_string_literal: true

module Extraction
  # Builds the configured OCR engine. "tesseract" runs the local binary
  # alone and is the production default; "paddle" still reads via the
  # PaddleOCR sidecar with Tesseract fallback when explicitly configured.
  # The full build wraps the engine in multi-pass enrichment (upscaled and
  # inverted variants merged into the word pool); base_engine is the
  # single-pass form for targeted work like region crops.
  module OcrFactory
    # Bump when anything that changes OCR output changes: engine models,
    # enrichment passes, upscale factor. Stale cache rows simply stop
    # being read. v3: mobile detection model.
    CACHE_VERSION = 3
    FAST_CACHE_VERSION = 2

    module_function

    def build
      EnrichedOcr.new(engine: base_engine)
    end

    def build_fast
      fast_engine
    end

    # Cache key for pools produced by build's engine configuration.
    def cache_key
      "#{Rails.application.config.x.extraction.ocr_engine}-enriched-v#{CACHE_VERSION}"
    end

    def fast_cache_key
      "#{Rails.application.config.x.extraction.ocr_engine}-strict-single-pass-v#{FAST_CACHE_VERSION}"
    end

    def base_engine
      tesseract = OcrClient.build
      return tesseract if Rails.application.config.x.extraction.ocr_engine == "tesseract"

      FallbackOcr.new(primary: PaddleOcrClient.build, fallback: tesseract)
    end

    def fast_engine
      return OcrClient.build if Rails.application.config.x.extraction.ocr_engine == "tesseract"

      PaddleOcrClient.build
    end
  end
end
