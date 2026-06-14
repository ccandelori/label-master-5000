# frozen_string_literal: true

module Extraction
  # Reads and caches OCR pages for front/back artwork, then renumbers each
  # blob's local page numbers into the verification's combined page space.
  module OcrPagePool
    module_function

    def read(artworks:, engine:, engine_key:)
      offset = 0
      artworks.flat_map do |artwork|
        pages = OcrCache.read_through(
          checksum: artwork.checksum, engine_key: engine_key, engine: engine
        ) { engine.read(data: artwork.data, content_type: artwork.content_type) }

        renumbered = pages.map do |page|
          OcrClient::Page.new(
            number: page.number + offset, width: page.width, height: page.height, words: page.words
          )
        end
        offset += pages.size
        renumbered
      end
    end
  end
end
