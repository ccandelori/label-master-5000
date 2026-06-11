# frozen_string_literal: true

module Extraction
  # Second-chance grounding for fields whose box is still a model estimate
  # after the page-level pass: the model's "roughly here" plus OCR's
  # "exactly this". The claimed region is cropped with padding, upscaled,
  # and re-read; a match maps back into the artwork's pixel space and
  # replaces the estimate. The model's placement error routinely exceeds
  # its own box, so a miss escalates through wider paddings (and an
  # inverted variant per rung, for light-on-dark print) before giving up.
  # Only fields on pages with standalone image bytes are refined (PDF
  # pages have none); misses and crop failures leave the field untouched.
  module RegionRefiner
    # First rung doubles as the display margin FieldCropsController uses.
    PADDING = 0.2
    # Calibrated on real misses: tight crops bisect the text when the
    # model's box is offset, and very wide crops drown small print in
    # surrounding artwork - escalate moderately, stop at first hit.
    PADDINGS = [ PADDING, 0.6, 1.2, 2.0 ].freeze
    CROP_UPSCALE = 3.0
    # Stamped on a field the full ladder missed, so reused extractions
    # skip re-attempting genuinely unreadable print. Bump when the ladder
    # or matching changes enough to deserve another try.
    ALGORITHM_VERSION = 1

    module_function

    # sources_by_page: {page => ArtworkSource} for pages that exist as
    # standalone images.
    def refine(payload:, sources_by_page:, engine:, threshold:)
      fields = payload["fields"]
      return payload if sources_by_page.empty? || !fields.is_a?(Hash)

      dimensions = {}
      refined = fields.to_h do |key, field|
        [ key, refine_field(field, payload, sources_by_page, dimensions, engine, threshold) ]
      end
      payload.merge("fields" => refined)
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({ event: "region_refine_failed", error: e.message.to_s.first(200) }))
      payload
    end

    def refine_field(field, payload, sources_by_page, dimensions, engine, threshold)
      return field unless candidate?(field, sources_by_page)

      target_tokens = BboxGrounder.tokenize(field["text"])
      return field if target_tokens.empty?

      page = field["page"] || 1
      data = sources_by_page.fetch(page).data
      image_w, image_h = (dimensions[page] ||= ImageVariants.dimensions(data))
      basis_w, basis_h = PageBasis.dimensions(payload, page) || [ image_w, image_h ]

      PADDINGS.each do |padding|
        rect = padded_rect(field["bbox"], image_w, image_h, basis_w, basis_h, padding)
        return field if rect.nil?

        crop = ImageVariants.crop(data, rect: rect, upscale_factor: CROP_UPSCALE)
        [ false, true ].each do |inverted|
          variant = inverted ? ImageVariants.invert(crop) : crop
          matched = match_in_crop(target_tokens, variant, engine, threshold)
          return relocate(field, matched, rect, image_w, image_h) unless matched.nil?
        end
      end

      field.merge("refine_attempted" => ALGORITHM_VERSION)
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({
        event: "region_refine_field_failed", error: e.message.to_s.first(200)
      }))
      field
    end

    # Contiguous-window match first; the gapped fallback tolerates an
    # unrelated word interleaved between the target's parts, which small
    # targeted crops hit often (stacked print next to other elements).
    def match_in_crop(target_tokens, crop, engine, threshold)
      words = engine.read(data: crop, content_type: "image/png").flat_map(&:words)
      BboxGrounder.best_match(target_tokens, words, threshold) ||
        BboxGrounder.gapped_match(target_tokens, words, threshold)
    end

    def relocate(field, matched, rect, image_w, image_h)
      crop_box = BboxGrounder.union_bbox(matched.map(&:first).uniq)
      field.merge(
        "bbox" => [
          rect[0] + crop_box[0] / CROP_UPSCALE,
          rect[1] + crop_box[1] / CROP_UPSCALE,
          crop_box[2] / CROP_UPSCALE,
          crop_box[3] / CROP_UPSCALE
        ].map(&:round),
        "bbox_basis" => [ image_w, image_h ],
        "bbox_source" => "ocr"
      )
    end

    def candidate?(field, sources_by_page)
      field.is_a?(Hash) &&
        field["bbox_source"] == "model" &&
        field["refine_attempted"] != ALGORITHM_VERSION &&
        field["text"].to_s.strip.present? &&
        field["bbox"].is_a?(Array) && field["bbox"].size == 4 &&
        sources_by_page.key?(field["page"] || 1)
    end

    # The model's box, scaled from its self-reported basis to the original
    # image's pixels, grown by the given padding (a fraction of the box's
    # own size) on every side, clamped to the image.
    def padded_rect(bbox, image_w, image_h, basis_w, basis_h, padding)
      x, y, w, h = bbox
      return nil unless [ x, y, w, h ].all? { |v| v.is_a?(Numeric) } && w.positive? && h.positive?

      scale_x = image_w.fdiv(basis_w)
      scale_y = image_h.fdiv(basis_h)
      pad_x = w * scale_x * padding
      pad_y = h * scale_y * padding

      left = (x * scale_x - pad_x).clamp(0, image_w - 1)
      top = (y * scale_y - pad_y).clamp(0, image_h - 1)
      right = ((x + w) * scale_x + pad_x).clamp(left + 1, image_w)
      bottom = ((y + h) * scale_y + pad_y).clamp(top + 1, image_h)
      [ left, top, right - left, bottom - top ]
    end
  end
end
