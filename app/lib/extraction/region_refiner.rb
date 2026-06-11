# frozen_string_literal: true

module Extraction
  # Second-chance grounding for fields whose box is still a model estimate
  # after the page-level pass: the model's "roughly here" plus OCR's
  # "exactly this". The claimed region is cropped with padding, upscaled,
  # and re-read; a match maps back into the artwork's pixel space and
  # replaces the estimate. Single-image artwork only (the model's page-1
  # basis maps cleanly onto the original bytes); misses and crop failures
  # leave the field untouched.
  module RegionRefiner
    PADDING = 0.2
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

      rect = padded_rect(field["bbox"], image_w, image_h, basis_w, basis_h)
      return field if rect.nil?

      crop = ImageVariants.crop(data, rect: rect, upscale_factor: CROP_UPSCALE)
      words = engine.read(data: crop, content_type: "image/png").flat_map(&:words)
      matched = BboxGrounder.best_match(target_tokens, words, threshold)
      return field if matched.nil?

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
    rescue OcrError => e
      Rails.logger.warn(JSON.generate({
        event: "region_refine_field_failed", error: e.message.to_s.first(200)
      }))
      field
    end

    def candidate?(field)
      field.is_a?(Hash) &&
        field["bbox_source"] == "model" &&
        field["text"].to_s.strip.present? &&
        field["bbox"].is_a?(Array) && field["bbox"].size == 4 &&
        (field["page"] || 1) == 1
    end

    # The model's box, scaled from its self-reported basis to the original
    # image's pixels, grown by PADDING on every side, clamped to the image.
    def padded_rect(bbox, image_w, image_h, basis_w, basis_h)
      x, y, w, h = bbox
      return nil unless [ x, y, w, h ].all? { |v| v.is_a?(Numeric) } && w.positive? && h.positive?

      scale_x = image_w.fdiv(basis_w)
      scale_y = image_h.fdiv(basis_h)
      pad_x = w * scale_x * PADDING
      pad_y = h * scale_y * PADDING

      left = (x * scale_x - pad_x).clamp(0, image_w - 1)
      top = (y * scale_y - pad_y).clamp(0, image_h - 1)
      right = ((x + w) * scale_x + pad_x).clamp(left + 1, image_w)
      bottom = ((y + h) * scale_y + pad_y).clamp(top + 1, image_h)
      [ left, top, right - left, bottom - top ]
    end
  end
end
