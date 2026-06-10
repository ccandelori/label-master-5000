# frozen_string_literal: true

module Extraction
  class ExtractionError < StandardError; end

  # Raised before any API call when a PDF exceeds the configured page cap.
  class PageLimitExceeded < ExtractionError; end

  # Raised after retries when the model response cannot be parsed into the
  # expected JSON shape.
  class ResponseParseError < ExtractionError; end
end
