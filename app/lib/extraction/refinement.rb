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
  # Runs on reused extractions too: each artwork's page pool is cached by
  # its blob checksum, and reconciliation depends on the application,
  # which can differ across duplicate artwork.
  class Refinement
    def initialize(engine:, region_engine:, region_refiner:, engine_key:, threshold:)
      @engine = engine
      @region_engine = region_engine
      @region_refiner = region_refiner
      @engine_key = engine_key
      @threshold = threshold
    end

    # artworks: Array of ArtworkSource, front first; a source's 1-based
    # position is its page (a front PDF contributes all its pages and,
    # by validation, never has a back companion).
    def refine(raw:, artworks:, application:)
      context = { label_application_id: application.id, engine_key: @engine_key }
      pages = instrument_stage("ocr_pooled_pages", context) do
        pooled_pages(artworks)
      end

      payload = instrument_stage("ocr_bbox_grounding", context) do
        BboxGrounder.ground(payload: raw, pages: pages, threshold: @threshold)
      end
      payload = instrument_stage("ocr_region_refinement", context) do
        @region_refiner.refine(
          payload: payload, sources_by_page: sources_by_page(artworks), engine: @region_engine, threshold: @threshold
        )
      end
      instrument_stage("ocr_field_reconciliation", context) do
        FieldReconciler.reconcile(
          payload: payload, pages: pages, application: application, threshold: @threshold
        )
      end
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({
        event: "extraction_refinement_failed", error: e.message.to_s.first(300)
      }))
      raw
    end

    private

    # Each blob is read (or cache-hit) on its own, with its pages numbered
    # from 1; renumbering to the concatenated sequence happens after the
    # cache boundary, so a blob reused as the front of another application
    # still hits the same cache row.
    def pooled_pages(artworks)
      OcrPagePool.read(artworks: artworks, engine: @engine, engine_key: @engine_key)
    end

    # Region crops need the original bytes of the page they cut from;
    # PDFs are excluded as before (their pages have no standalone bytes).
    def sources_by_page(artworks)
      artworks.each_with_index.reject { |artwork, _| artwork.pdf? }.to_h do |artwork, index|
        [ index + 1, artwork ]
      end
    end

    def instrument_stage(stage, payload)
      ActiveSupport::Notifications.instrument(
        "verification.stage.label_verifier",
        payload.merge(stage: stage)
      ) do
        yield
      end
    end
  end
end
