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
    @enabled = true

    module_function

    def enabled=(value)
      @enabled = value
    end

    def enabled?
      @enabled
    end

    def read_through(checksum:, engine_key:, engine:)
      unless enabled?
        return ActiveSupport::Notifications.instrument(
          "verification.ocr_cache.label_verifier",
          checksum: checksum, engine_key: engine_key, hit: false, bypassed: true
        ) do
          yield
        end
      end

      cached = OcrReading.find_by(blob_checksum: checksum, engine_key: engine_key)
      if cached
        return ActiveSupport::Notifications.instrument(
          "verification.ocr_cache.label_verifier",
          checksum: checksum, engine_key: engine_key, hit: true
        ) do
          deserialize(cached.pages)
        end
      end

      pages = ActiveSupport::Notifications.instrument(
        "verification.ocr_cache.label_verifier",
        checksum: checksum, engine_key: engine_key, hit: false
      ) do
        yield
      end
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
            {
              "text" => safe_text(word.text),
              "x" => word.x,
              "y" => word.y,
              "width" => word.width,
              "height" => word.height,
              "confidence" => word.confidence
            }.compact
          end
        }
      end
    end

    def deserialize(raw)
      raw.map do |page|
        OcrClient::Page.new(
          number: page["number"], width: page["width"], height: page["height"],
          words: page["words"].map do |word|
            OcrClient.build_word(
              text: word["text"], x: word["x"], y: word["y"],
              width: word["width"], height: word["height"],
              confidence: word["confidence"]
            )
          end
        )
      end
    end

    def safe_text(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end
  end
end
