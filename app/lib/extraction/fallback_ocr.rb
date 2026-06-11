# frozen_string_literal: true

module Extraction
  # Tries the primary OCR engine and falls back to the secondary when it
  # fails outright (sidecar down, unreadable response). A primary that
  # succeeds with poor results is not second-guessed - engine quality is
  # a configuration decision, not a per-request vote.
  #
  # degraded? sticks once any read has fallen back: output produced by a
  # mix of engines must not be cached as if the primary had read it.
  # Engines are built fresh per verification, scoping the flag naturally.
  class FallbackOcr
    def initialize(primary:, fallback:)
      @primary = primary
      @fallback = fallback
      @degraded = false
    end

    def degraded?
      @degraded
    end

    def read(data:, content_type:)
      @primary.read(data: data, content_type: content_type)
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({
        event: "ocr_primary_failed", error: e.message.to_s.first(200)
      }))
      @degraded = true
      @fallback.read(data: data, content_type: content_type)
    end
  end
end
