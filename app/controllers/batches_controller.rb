# frozen_string_literal: true

require "csv"

class BatchesController < ApplicationController
  before_action :set_batch, only: %i[show export retry_failed]

  def new
    @batch = Batch.new
    @ingest_errors = []
  end

  def create
    csv_file = params.dig(:batch, :csv_file)
    images = Array(params.dig(:batch, :images)).reject(&:blank?)
    name = params.dig(:batch, :name).presence || "Batch #{Time.current.strftime('%b %-d, %H:%M')}"

    if csv_file.blank? || images.empty?
      return render_ingest_failure(name, [ missing_inputs_error(csv_file, images) ])
    end

    result = BatchIngest.parse(csv_file.read, images.map { |i| i.original_filename })
    return render_ingest_failure(name, result.errors) unless result.valid?

    @batch = create_batch!(name, result.rows, images)
    @batch.label_applications.find_each { |application| VerifyLabelJob.perform_later(application.id) }
    redirect_to @batch, notice: "#{result.rows.size} labels queued - results fill in live."
  end

  def show
    @applications = @batch.label_applications.order(:row_number).includes(:verifications, artwork_attachment: :blob)
    @verdict_filter = params[:verdict].presence
    if @verdict_filter
      @applications = @applications.select { |a| a.latest_verification&.overall_verdict == @verdict_filter }
    end
  end

  def export
    respond_to do |format|
      format.csv do
        send_data export_csv, filename: "#{@batch.name.parameterize}-results.csv", type: "text/csv"
      end
    end
  end

  def retry_failed
    retried = 0
    @batch.label_applications.find_each do |application|
      latest = application.latest_verification
      next unless latest.nil? || latest.error?

      VerifyLabelJob.perform_later(application.id)
      retried += 1
    end
    redirect_to @batch, notice: "Re-queued #{retried} #{'row'.pluralize(retried)}."
  end

  private

  def set_batch
    @batch = Batch.find(params[:id])
  end

  def missing_inputs_error(csv_file, images)
    message = csv_file.blank? ? "A CSV file is required" : "At least one label image is required"
    BatchIngest::RowError.new(row_number: nil, kind: :missing_input, message: message)
  end

  def render_ingest_failure(name, errors)
    @batch = Batch.new(name: name)
    @ingest_errors = errors
    render :new, status: :unprocessable_entity
  end

  def create_batch!(name, rows, images)
    images_by_name = images.index_by { |i| i.original_filename }

    Batch.transaction do
      batch = Batch.create!(name: name, status: "processing", total_rows: rows.size)
      rows.each do |row|
        application = batch.label_applications.build(row.attributes.merge(row_number: row.row_number))
        upload = images_by_name.fetch(row.image_filename)
        upload.rewind
        application.artwork.attach(
          io: upload, filename: upload.original_filename, content_type: upload.content_type
        )
        application.save!
      end
      batch
    end
  end

  def export_csv
    CSV.generate do |csv|
      csv << %w[row serial_number brand_name beverage_type overall_verdict decision findings]
      @batch.label_applications.order(:row_number).each do |application|
        verification = application.latest_verification
        findings = verification&.field_checks.to_a
                                .select { |c| %w[fail needs_review].include?(c.verdict) }
                                .map { |c| "#{c.field}: #{c.note} (#{c.citation})" }
                                .join(" | ")
        csv << [
          application.row_number,
          application.serial_number,
          application.brand_name,
          application.beverage_type,
          verification&.overall_verdict || "pending",
          verification&.decision,
          findings
        ]
      end
    end
  end
end
