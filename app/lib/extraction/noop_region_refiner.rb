# frozen_string_literal: true

module Extraction
  # Keeps synchronous verification bounded by preserving the page-level
  # OCR grounding and reconciliation while skipping targeted crop OCR.
  module NoopRegionRefiner
    module_function

    def refine(payload:, sources_by_page:, engine:, threshold:)
      payload
    end
  end
end
