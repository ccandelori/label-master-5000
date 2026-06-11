# frozen_string_literal: true

module Extraction
  # Resolves the model's self-reported coordinate basis for one page of a
  # payload: the per-page "pages" list when present, else the legacy
  # top-level image_width/image_height - which describe page 1 only, so
  # later pages without an entry resolve to nothing and their model boxes
  # cannot be mapped (callers skip them rather than scale against the
  # wrong raster).
  module PageBasis
    module_function

    def dimensions(payload, page)
      entry = Array(payload["pages"]).find { |p| p.is_a?(Hash) && p["page"] == page }
      return [ entry["width"], entry["height"] ] if usable?(entry&.values_at("width", "height"))

      pair = payload.values_at("image_width", "image_height")
      page == 1 && usable?(pair) ? pair : nil
    end

    def usable?(pair)
      pair.is_a?(Array) && pair.size == 2 && pair.all? { |n| n.is_a?(Numeric) && n.positive? }
    end
  end
end
