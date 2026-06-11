# frozen_string_literal: true

module Extraction
  # The OCR-dependent half of a verification: re-anchors the model's
  # boxes to word geometry, retries still-ungrounded fields with targeted
  # region crops, then reconciles the application's declared values
  # against the located print. Strictly best-effort - any OCR failure
  # (missing binary, unreadable artwork, sidecar down past its retries)
  # logs a warning and returns the payload unchanged; refinement never
  # fails a verification.
  #
  # Runs on reused extractions too: the page pool is cached by artwork
  # checksum, and reconciliation depends on the application, which can
  # differ across duplicate artwork.
  class Refinement
    def initialize(engine:, engine_key:, threshold:)
      @engine = engine
      @engine_key = engine_key
      @threshold = threshold
    end

    def refine(raw:, data:, content_type:, application:)
      pages = pooled_pages(application, data, content_type)

      payload = BboxGrounder.ground(payload: raw, pages: pages, threshold: @threshold)
      payload = RegionRefiner.refine(
        payload: payload, data: data, content_type: content_type, engine: @engine, threshold: @threshold
      )
      FieldReconciler.reconcile(
        payload: payload, pages: pages, application: application, threshold: @threshold
      )
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({
        event: "extraction_refinement_failed", error: e.message.to_s.first(300)
      }))
      raw
    end

    private

    def pooled_pages(application, data, content_type)
      OcrCache.read_through(
        checksum: application.artwork.blob.checksum,
        engine_key: @engine_key,
        engine: @engine
      ) { @engine.read(data: data, content_type: content_type) }
    end
  end
end
