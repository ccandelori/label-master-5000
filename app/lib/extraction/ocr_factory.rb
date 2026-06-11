# frozen_string_literal: true

module Extraction
  # Builds the configured OCR engine. "paddle" (the default) reads via
  # the PaddleOCR sidecar with Tesseract as the automatic fallback when
  # the sidecar is down; "tesseract" runs the local binary alone.
  module OcrFactory
    module_function

    def build
      tesseract = OcrClient.build
      return tesseract if Rails.application.config.x.extraction.ocr_engine == "tesseract"

      FallbackOcr.new(primary: PaddleOcrClient.build, fallback: tesseract)
    end
  end
end
