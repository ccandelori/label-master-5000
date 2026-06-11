# frozen_string_literal: true

module Extraction
  class ExtractionError < StandardError; end

  # What every extractor's extract(data:, content_type:) returns,
  # whichever provider produced it. raw conforms to Schema::RESPONSE_SCHEMA;
  # model_id is the provider's model identifier, which also keys
  # extraction reuse (one model's reading must never be reused as
  # another's).
  ExtractorResult = Data.define(:facts, :raw, :model_id, :latency_ms)

  # Raised before any API call when a PDF exceeds the configured page cap.
  class PageLimitExceeded < ExtractionError; end

  # Raised after retries when the model response cannot be parsed into the
  # expected JSON shape.
  class ResponseParseError < ExtractionError; end

  # Raised when OCR cannot produce word boxes for the artwork (missing
  # binary, rasterization failure, unreadable bytes). Callers treat OCR
  # grounding as best-effort and fall back to the model's boxes.
  class OcrError < ExtractionError; end

  # The sidecar could not be reached at all (connection refused or reset,
  # typically a worker recycle). Safe to retry: no inference ran. A read
  # timeout deliberately is NOT this class - retrying a slow inference
  # re-submits the same expensive work to an already-struggling worker.
  class OcrConnectionError < OcrError; end
end
