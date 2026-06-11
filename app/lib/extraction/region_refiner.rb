# frozen_string_literal: true

module Extraction
  # Second-chance grounding for fields whose box is still a model estimate
  # after the page-level pass: the model's "roughly here" plus OCR's
  # "exactly this". The claimed region is cropped with padding, upscaled,
  # and re-read; a match maps back into the artwork's pixel space and
  # replaces the estimate. The model's placement error routinely exceeds
  # its own box, so a miss escalates through wider paddings (and an
  # inverted variant per rung, for light-on-dark print) before giving up.
  # Single-image artwork only (the model's page-1 basis maps cleanly onto
  # the original bytes); misses and crop failures leave the field
  # untouched.
  module RegionRefiner
    # First rung doubles as the display margin FieldCropsController uses.
    PADDING = 0.2
    # Calibrated on real misses: tight crops bisect the text when the
    # model's box is offset, and very wide crops drown small print in
    # surrounding artwork - escalate moderately, stop at first hit.
    PADDINGS = [ PADDING, 0.6, 1.2, 2.0 ].freeze
    CROP_UPSCALE = 3.0

    module_function

    def refine(payload:, data:, content_type:, engine:, threshold:)
      return payload if content_type == OcrClient::PDF_CONTENT_TYPE

      fields = payload["fields"]
      return payload unless fields.is_a?(Hash)

      image_w, image_h = ImageVariants.dimensions(data)
      basis_w = payload["image_width"] || image_w
      basis_h = payload["image_height"] || image_h

      refined = fields.to_h do |key, field|
        [ key, refine_field(field, data, image_w, image_h, basis_w, basis_h, engine, threshold) ]
      end
      payload.merge("fields" => refined)
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({ event: "region_refine_failed", error: e.message.to_s.first(200) }))
      payload
    end

    def refine_field(field, data, image_w, image_h, basis_w, basis_h, engine, threshold)
      return field unless candidate?(field)

      target_tokens = BboxGrounder.tokenize(field["text"])
      return field if target_tokens.empty?

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

      field
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

    def candidate?(field)
      field.is_a?(Hash) &&
        field["bbox_source"] == "model" &&
        field["text"].to_s.strip.present? &&
        field["bbox"].is_a?(Array) && field["bbox"].size == 4 &&
        (field["page"] || 1) == 1
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
