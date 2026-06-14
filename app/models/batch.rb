# frozen_string_literal: true

require "csv"

class Batch < ApplicationRecord
  has_many :label_applications, dependent: :destroy

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed"
  }, validate: true
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

  validates :name, :source_kind, presence: true

  def self.create_from_ingest!(name:, rows:, images:)
    images_by_name = images.index_by { |image| image.original_filename }

    transaction do
      batch = create!(
        name: name,
        source_kind: "batch_upload",
        status: "processing",
        total_rows: rows.size,
        processing_started_at: Time.current
      )
      rows.each do |row|
        application = batch.label_applications.build(
          row.attributes.merge(row_number: row.row_number, source_kind: "batch_upload")
        )
        attach_upload(application.artwork, images_by_name.fetch(row.image_filename))
        attach_upload(application.back_artwork, images_by_name.fetch(row.back_image_filename)) if row.back_image_filename
        application.save!
      end
      batch
    end
  end

  def self.create_from_application_pdfs!(name:, rows:, channel:, source_kind:)
    transaction do
      batch = create!(
        name: name,
        source_kind: source_kind,
        status: "processing",
        total_rows: rows.size,
        processing_started_at: Time.current
      )
      attach_application_pdf_rows(batch, rows: rows, channel: channel, source_kind: source_kind)
      batch
    end
  end

  def self.seed_application_pdfs!(dir: Rails.root.join("downloads/ttb_cola_approved_applications_2026-06-13"))
    name = "TTB approved application PDFs"
    directory = Pathname(dir)
    sources = directory.glob("*.pdf").sort.map { |path| ApplicationPdfIngest::Source.from_path(path) }
    manifest = directory.join("manifest.json")
    result = ApplicationPdfIngest.parse(sources: sources, manifest_text: manifest.exist? ? manifest.read : nil)
    raise ArgumentError, result.errors.map(&:message).join("; ") unless result.valid?

    transaction do
      batch = find_or_create_by!(name: name) do |new_batch|
        new_batch.source_kind = "seed_application_pdf"
        new_batch.status = "pending"
      end
      batch.label_applications.destroy_all
      batch.update!(
        source_kind: "seed_application_pdf",
        status: "pending",
        total_rows: result.rows.size,
        processing_started_at: nil,
        processing_completed_at: nil
      )
      attach_application_pdf_rows(batch, rows: result.rows, channel: "submitted", source_kind: "seed_application_pdf")
      batch
    end
  end

  def verify_later(provider:, model:, mode:)
    start_processing!
    label_applications.find_each do |application|
      application.verify_later(provider: provider, model: model, mode: mode)
    end
  end

  def retry_failed_verifications_later(provider:, model:, mode:)
    retried = 0

    label_applications.find_each do |application|
      next unless application.unchecked_or_error?

      application.verify_later(provider: provider, model: model, mode: mode)
      retried += 1
    end

    start_processing! if retried.positive?
    retried
  end

  def submit_to_ttb
    submitted = 0

    label_applications.pre_review.find_each do |application|
      submitted += 1 if application.submit_to_ttb
    end

    submitted
  end

  def results_csv
    CSV.generate do |csv|
      csv << %w[row serial_number brand_name beverage_type overall_verdict decision findings]
      label_applications.order(:row_number).each do |application|
        verification = application.latest_verification
        csv << [
          application.row_number,
          application.serial_number,
          application.brand_name,
          application.beverage_type,
          verification&.overall_verdict || "pending",
          verification&.decision,
          export_findings(verification)
        ]
      end
    end
  end

  def done_count
    counts = attempt_state_counts
    terminal = counts.values_at("passed", "failed", "needs_review", "error").compact.sum
    return terminal if counts.any?

    label_applications.where(id: Verification.select(:label_application_id)).count
  end

  def progress_percent
    return 0 if total_rows.zero?

    (done_count * 100.0 / total_rows).round
  end

  def verdict_counts
    latest_ids = Verification.group(:label_application_id)
                             .where(label_application: label_applications)
                             .maximum(:id).values
    Verification.where(id: latest_ids).group(:overall_verdict).count
  end

  def attempt_state_counts
    VerificationAttempt.where(id: latest_attempt_ids).group(:state).count
  end

  def queued_count
    attempt_state_counts["queued"] || 0
  end

  def processing_count
    attempt_state_counts["processing"] || 0
  end

  def operational_error_count
    attempt_state_counts["error"] || 0
  end

  def refresh_processing_state!
    counts = attempt_state_counts
    return if counts.empty?

    if counts.values_at("queued", "processing").compact.sum.positive?
      start_processing!
    elsif !completed?
      update!(status: "completed", processing_completed_at: Time.current)
    elsif processing_completed_at.nil?
      update!(processing_completed_at: Time.current)
    end
  end

  def start_processing!
    update!(
      status: "processing",
      processing_started_at: processing_started_at || Time.current,
      processing_completed_at: nil
    )
  end

  private

  def latest_attempt_ids
    VerificationAttempt.where(label_application_id: label_applications.select(:id))
                       .group(:label_application_id)
                       .maximum(:id)
                       .values
  end

  def export_findings(verification)
    verification&.field_checks.to_a
                .select { |check| %w[fail needs_review].include?(check.verdict) }
                .map { |check| "#{check.field}: #{check.note} (#{check.citation})" }
                .join(" | ")
  end

  def self.attach_upload(attachment, upload)
    upload.rewind
    attachment.attach(
      io: upload,
      filename: upload.original_filename,
      content_type: upload.content_type
    )
  end
  private_class_method :attach_upload

  def self.attach_binary(attachment, binary)
    attachment.attach(
      io: StringIO.new(binary.data),
      filename: binary.filename,
      content_type: binary.content_type
    )
  end
  private_class_method :attach_binary

  def self.attach_application_pdf_rows(batch, rows:, channel:, source_kind:)
    rows.each do |row|
      application = batch.label_applications.build(
        row.attributes.merge(row_number: row.row_number, channel: channel, source_kind: source_kind)
      )
      attach_binary(application.application_pdf, row.application_pdf)
      attach_binary(application.artwork, row.artworks.first)
      attach_binary(application.back_artwork, row.artworks.second) if row.artworks.second
      application.save!
    end
  end
  private_class_method :attach_application_pdf_rows
end
