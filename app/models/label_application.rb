# frozen_string_literal: true

class LabelApplication < ApplicationRecord
  ARTWORK_CONTENT_TYPES = %w[image/jpeg image/png image/webp application/pdf].freeze
  ARTWORK_MAX_BYTES = 20.megabytes
  REVIEWABLE_SOURCE_KINDS = %w[manual batch_upload application_pdf_upload seed_sample seed_application_pdf demo].freeze
  VALIDATION_HISTORY_SOURCE_KINDS = %w[manual batch_upload application_pdf_upload].freeze
  VALIDATION_SAMPLE_SOURCE_KINDS = %w[seed_application_pdf seed_sample demo].freeze
  VALIDATION_COPY_ATTRIBUTES = %w[
    serial_number beverage_type imported brand_name fanciful_name applicant_name_address
    alcohol_content net_contents country_of_origin container_embossed_info varietals
    appellation vintage_year declared_class_type actual_alcohol_content
    contains_fd_c_yellow_5 contains_cochineal_carmine contains_sulfites_10ppm
    contains_saccharin contains_aspartame contains_added_coloring
  ].freeze

  belongs_to :batch, optional: true
  has_many :verifications, dependent: :destroy
  has_many :verification_attempts, dependent: :destroy
  # artwork is the front (brand) label - the one the placement rules name
  # by role; back_artwork is optional and image-only (a PDF front already
  # carries every panel as pages).
  has_one_attached :artwork
  has_one_attached :back_artwork
  has_one_attached :application_pdf

  enum :beverage_type, { malt: "malt", wine: "wine", spirits: "spirits" }

  # pre_review records live in the validation workspace; submitted records
  # have been filed (here: via the "Submit to TTB" bridge, simulating a
  # COLAs Online filing) and can receive human filing decisions.
  enum :channel, { pre_review: "pre_review", submitted: "submitted" }
  enum :source_kind, {
    manual: "manual",
    batch_upload: "batch_upload",
    application_pdf_upload: "application_pdf_upload",
    registry_eval: "registry_eval",
    seed_sample: "seed_sample",
    seed_application_pdf: "seed_application_pdf",
    mutation: "mutation",
    demo: "demo"
  }, validate: true

  # New validation records and channel promotions change which rows the
  # history page shows; a debounced refresh keeps open history pages live.
  after_commit -> { broadcast_refresh_later_to :validation_history }

  validates :serial_number, :beverage_type, :brand_name, :applicant_name_address, :net_contents, presence: true
  validates :source_kind, presence: true
  validates :country_of_origin, presence: { message: "is required for imported products" }, if: :imported?
  validates :alcohol_content, :actual_alcohol_content,
            numericality: { greater_than_or_equal_to: 0, less_than: 100 }, allow_nil: true
  validates :vintage_year,
            numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: 2100 }, allow_nil: true
  validate :artwork_constraints
  validate :quarantine_reasons_are_present

  scope :reviewer_visible, -> {
    submitted.where(source_kind: REVIEWABLE_SOURCE_KINDS, quarantined_at: nil)
  }
  scope :validation_history_visible, -> {
    where(source_kind: VALIDATION_HISTORY_SOURCE_KINDS, quarantined_at: nil)
  }
  scope :validation_samples, -> {
    where(source_kind: VALIDATION_SAMPLE_SOURCE_KINDS, quarantined_at: nil)
      .includes(:batch, artwork_attachment: :blob, back_artwork_attachment: :blob, application_pdf_attachment: :blob)
      .order(:brand_name, :serial_number)
  }

  def latest_verification
    verifications.order(created_at: :desc).first
  end

  def latest_verification_attempt
    verification_attempts.order(created_at: :desc).first
  end

  # The latest verification is the authoritative one for review, regardless
  # of the extraction mode that produced it.
  def review_verification
    latest_verification
  end

  def verify_later(provider:, model:, mode:)
    attempt = verification_attempts.create!
    VerifyLabelJob.set(priority: VerifyLabelJob::DEFAULT_PRIORITY).perform_later(id, provider, model, mode, attempt.id)
  end

  def submit_to_ttb
    return false if submitted?

    submitted!
    true
  end

  def reviewer_visible?
    submitted? && REVIEWABLE_SOURCE_KINDS.include?(source_kind) && quarantined_at.nil?
  end

  def validation_history_visible?
    VALIDATION_HISTORY_SOURCE_KINDS.include?(source_kind) && quarantined_at.nil?
  end

  def build_validation_copy
    copy = self.class.new(attributes.slice(*VALIDATION_COPY_ATTRIBUTES).merge(
      "channel" => "pre_review",
      "source_kind" => "manual"
    ))
    copy.artwork.attach(artwork.blob) if artwork.attached?
    copy.back_artwork.attach(back_artwork.blob) if back_artwork.attached?
    copy.application_pdf.attach(application_pdf.blob) if application_pdf.attached?
    copy
  end

  def quarantine!(reasons:)
    update!(quarantined_at: Time.current, quarantine_reasons: reasons.map(&:to_s).map(&:strip).reject(&:empty?).uniq)
  end

  def unchecked_or_error?
    verification = latest_verification
    verification.nil? || verification.error?
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
    if application_pdf.attached?
      unless application_pdf.content_type == "application/pdf"
        errors.add(:application_pdf, "must be a PDF")
      end

      if application_pdf.byte_size > ARTWORK_MAX_BYTES
        errors.add(:application_pdf, "must be 20 MB or smaller")
      end
    end

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

  def quarantine_reasons_are_present
    quarantine_reasons.each do |reason|
      errors.add(:quarantine_reasons, "cannot include blank values") if reason.blank?
    end
  end
end
