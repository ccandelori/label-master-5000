# frozen_string_literal: true

# Serves the evidence crop for one located field: the artwork clipped to
# the region the pipeline claims the value sits in, so a human verifies
# the find by looking at the actual pixels rather than trusting a box on
# a thumbnail. Crops are cut on demand from the original artwork of the
# page the field was read on (1 = front label, 2 = back label).
class FieldCropsController < ApplicationController
  def show
    application = LabelApplication.find(params[:label_application_id])
    field = params[:field].to_s
    return head :not_found unless Extraction::Schema::FIELD_KEYS.include?(field)

    verification = application.verifications.order(created_at: :desc).first
    slot = verification&.extraction&.dig("fields", field)
    bbox = slot && slot["bbox"]
    return head :not_found unless bbox.is_a?(Array) && bbox.size == 4

    # Crops are evidence, so only OCR-anchored boxes can be cut directly
    # from the artwork. VLM-estimated boxes remain review spotlight hints.
    return head :not_found unless slot["bbox_source"] == "ocr"

    page = slot["page"] || 1
    attachment = page == 1 ? application.artwork : application.back_artwork
    return head :not_found unless page <= 2 && attachment.attached? && attachment.image?

    data = attachment.download
    image_w, image_h = Extraction::ImageVariants.dimensions(data)
    basis = slot["bbox_basis"] ||
            Extraction::PageBasis.dimensions(verification.extraction, page) ||
            [ image_w, image_h ]
    rect = Extraction::RegionRefiner.padded_rect(
      bbox, image_w, image_h, basis[0], basis[1], Extraction::RegionRefiner::PADDING
    )
    return head :not_found if rect.nil?

    expires_in 10.minutes
    send_data Extraction::ImageVariants.crop(data, rect: rect, upscale_factor: 1.0),
              type: "image/png", disposition: "inline"
  rescue
    head :unprocessable_entity
  end
end
