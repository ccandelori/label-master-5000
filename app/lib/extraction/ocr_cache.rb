# frozen_string_literal: true

module Extraction
  # Checksum-keyed cache over the page-level OCR pool, mirroring the
  # extraction reuse strategy: identical artwork bytes always read the
  # same, so the multi-pass page reads run once per artwork and engine
  # configuration. Targeted region crops are not cached - they depend on
  # which fields are still unlocated, and they are small and fast.
  #
  # A pool that a fallback engine contributed to (engine.degraded?) is
  # returned but never persisted: caching a Tesseract-degraded read under
  # the primary engine's key would silently pin worse geometry.
  module OcrCache
    module_function

    def read_through(checksum:, engine_key:, engine:)
      cached = OcrReading.find_by(blob_checksum: checksum, engine_key: engine_key)
      return deserialize(cached.pages) if cached

      pages = yield
      unless engine.respond_to?(:degraded?) && engine.degraded?
        OcrReading.create!(blob_checksum: checksum, engine_key: engine_key, pages: serialize(pages))
      end
      pages
    rescue ActiveRecord::RecordNotUnique
      pages
    end

    def serialize(pages)
      pages.map do |page|
        {
          "number" => page.number, "width" => page.width, "height" => page.height,
          "words" => page.words.map do |word|
            { "text" => word.text, "x" => word.x, "y" => word.y, "width" => word.width, "height" => word.height }
          end
        }
      end
    end

    def deserialize(raw)
      raw.map do |page|
        OcrClient::Page.new(
          number: page["number"], width: page["width"], height: page["height"],
          words: page["words"].map do |word|
            OcrClient::Word.new(
              text: word["text"], x: word["x"], y: word["y"],
              width: word["width"], height: word["height"]
            )
          end
        )
      end
    end
  end
end
