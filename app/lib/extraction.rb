# frozen_string_literal: true

module Extraction
  class ExtractionError < StandardError; end

  # Raised before any API call when a PDF exceeds the configured page cap.
  class PageLimitExceeded < ExtractionError; end

  # Raised after retries when the model response cannot be parsed into the
  # expected JSON shape.
  class ResponseParseError < ExtractionError; end

  # Raised when OCR cannot produce word boxes for the artwork (missing
  # binary, rasterization failure, unreadable bytes). Callers treat OCR
  # grounding as best-effort and fall back to the model's boxes.
  class OcrError < ExtractionError; end
end
