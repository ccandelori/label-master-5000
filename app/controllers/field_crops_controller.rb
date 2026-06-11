# frozen_string_literal: true

# Serves the evidence crop for one located field: the artwork clipped to
# the region the pipeline claims the value sits in, so a human verifies
# the find by looking at the actual pixels rather than trusting a box on
# a thumbnail. Crops are cut on demand from the original artwork.
class FieldCropsController < ApplicationController
  def show
    application = LabelApplication.find(params[:label_application_id])
    field = params[:field].to_s
    return head :not_found unless Extraction::Schema::FIELD_KEYS.include?(field)
    return head :not_found unless application.artwork.attached? && application.artwork.image?

    verification = application.verifications.order(created_at: :desc).first
    slot = verification&.extraction&.dig("fields", field)
    bbox = slot && slot["bbox"]
    return head :not_found unless bbox.is_a?(Array) && bbox.size == 4 && (slot["page"] || 1) == 1

    data = application.artwork.download
    image_w, image_h = Extraction::ImageVariants.dimensions(data)
    basis = slot["bbox_basis"] ||
            [ verification.extraction["image_width"] || image_w, verification.extraction["image_height"] || image_h ]
    rect = Extraction::RegionRefiner.padded_rect(
      bbox, image_w, image_h, basis[0], basis[1], Extraction::RegionRefiner::PADDING
    )
    return head :not_found if rect.nil?

    expires_in 10.minutes
    send_data Extraction::ImageVariants.crop(data, rect: rect, upscale_factor: 1.0),
              type: "image/png", disposition: "inline"
  rescue Extraction::OcrError
    head :unprocessable_entity
  end
end
