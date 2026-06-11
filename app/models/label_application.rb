# frozen_string_literal: true

class LabelApplication < ApplicationRecord
  ARTWORK_CONTENT_TYPES = %w[image/jpeg image/png image/webp application/pdf].freeze
  ARTWORK_MAX_BYTES = 20.megabytes

  belongs_to :batch, optional: true
  has_many :verifications, dependent: :destroy
  # artwork is the front (brand) label - the one the placement rules name
  # by role; back_artwork is optional and image-only (a PDF front already
  # carries every panel as pages).
  has_one_attached :artwork
  has_one_attached :back_artwork

  enum :beverage_type, { malt: "malt", wine: "wine", spirits: "spirits" }

  # pre_review records live in the manufacturer sandbox; submitted records
  # have been filed (here: via the "Submit to TTB" bridge, simulating a
  # COLAs Online filing) and are what the reviewer queue consumes.
  enum :channel, { pre_review: "pre_review", submitted: "submitted" }

  validates :serial_number, :beverage_type, :brand_name, :applicant_name_address, :net_contents, presence: true
  validates :country_of_origin, presence: { message: "is required for imported products" }, if: :imported?
  validates :alcohol_content, :actual_alcohol_content,
            numericality: { greater_than_or_equal_to: 0, less_than: 100 }, allow_nil: true
  validates :vintage_year,
            numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: 2100 }, allow_nil: true
  validate :artwork_constraints

  def latest_verification
    verifications.order(created_at: :desc).first
  end

  # Form-friendly representation of the varietals array.
  def varietals_list
    varietals.join(", ")
  end

  def varietals_list=(value)
    self.varietals = value.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # Formula data (TTB F 5100.51) is optional; when present the rules engine
  # runs its stricter tier. Presence of any formula field counts.
  def formula_provided?
    declared_class_type.present? ||
      actual_alcohol_content.present? ||
      !contains_fd_c_yellow_5.nil? ||
      !contains_cochineal_carmine.nil? ||
      !contains_sulfites_10ppm.nil? ||
      !contains_saccharin.nil? ||
      !contains_aspartame.nil? ||
      !contains_added_coloring.nil?
  end

  private

  def artwork_constraints
    if artwork.attached?
      unless ARTWORK_CONTENT_TYPES.include?(artwork.content_type)
        errors.add(:artwork, "must be JPEG, PNG, WebP, or PDF")
      end

      if artwork.byte_size > ARTWORK_MAX_BYTES
        errors.add(:artwork, "must be 20 MB or smaller")
      end
    end

    return unless back_artwork.attached?

    unless (ARTWORK_CONTENT_TYPES - [ "application/pdf" ]).include?(back_artwork.content_type)
      errors.add(:back_artwork, "must be JPEG, PNG, or WebP")
    end

    if back_artwork.byte_size > ARTWORK_MAX_BYTES
      errors.add(:back_artwork, "must be 20 MB or smaller")
    end

    if artwork.attached? && artwork.content_type == "application/pdf"
      errors.add(:back_artwork, "cannot accompany PDF artwork - a PDF already carries every label panel as pages")
    end
  end
end
