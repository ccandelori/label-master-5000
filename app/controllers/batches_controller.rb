# frozen_string_literal: true

class BatchesController < ApplicationController
  before_action :set_batch, only: :show
  before_action { @area = :pre_review }

  def new
    @batch = Batch.new
    @ingest_errors = []
    @ocr_ready = Extraction::RuntimeDependencies.check_ocr_ready
  end

  def create
    csv_file = params.dig(:batch, :csv_file)
    manifest_file = params.dig(:batch, :manifest_file)
    images = Array(params.dig(:batch, :images)).reject(&:blank?)
    application_pdfs = Array(params.dig(:batch, :application_pdfs)).reject(&:blank?)
    name = params.dig(:batch, :name).presence || "Batch #{Time.current.strftime('%b %-d, %H:%M')}"

    if application_pdfs.any?
      return create_from_application_pdfs(name: name, application_pdfs: application_pdfs, manifest_file: manifest_file)
    end

    if csv_file.blank? || images.empty?
      return render_ingest_failure(name, [ missing_inputs_error(csv_file, images) ])
    end

    result = BatchIngest.parse(
      csv_file.read,
      images.map { |image| image.original_filename },
      manifest_text: manifest_file&.read
    )
    return render_ingest_failure(name, result.errors) unless result.valid?

    readiness = Extraction::RuntimeDependencies.check_ocr_ready
    return render_ingest_failure(name, [ ocr_readiness_error(readiness) ]) unless readiness.ok?

    selection = selected_pre_review_validation_mode
    @batch = Batch.create_from_ingest!(name: name, rows: result.rows, images: images)
    @batch.verify_later(provider: selection.provider, model: selection.model, mode: selection.mode)
    redirect_to @batch, notice: "#{result.rows.size} labels queued - results fill in live."
  end

  def show
    @applications = @batch.label_applications.order(:row_number)
                          .includes(:verification_attempts, :verifications, artwork_attachment: :blob)
    @verdict_filter = params[:verdict].presence
    if @verdict_filter
      @applications = @applications.select { |a| a.latest_verification&.overall_verdict == @verdict_filter }
    end
  end

  private

  def set_batch
    @batch = Batch.find(params[:id])
  end

  def missing_inputs_error(csv_file, images)
    message = csv_file.blank? ? "A CSV file is required" : "At least one label image is required"
    BatchIngest::RowError.new(row_number: nil, kind: :missing_input, message: message)
  end

  def create_from_application_pdfs(name:, application_pdfs:, manifest_file:)
    result = ApplicationPdfIngest.parse(
      sources: application_pdfs.map { |pdf| ApplicationPdfIngest::Source.from_upload(pdf) },
      manifest_text: manifest_file&.read
    )
    return render_ingest_failure(name, result.errors) unless result.valid?

    readiness = Extraction::RuntimeDependencies.check_ocr_ready
    return render_ingest_failure(name, [ ocr_readiness_error(readiness) ]) unless readiness.ok?

    selection = selected_pre_review_validation_mode
    @batch = Batch.create_from_application_pdfs!(
      name: name,
      rows: result.rows,
      channel: "pre_review",
      source_kind: "application_pdf_upload"
    )
    @batch.verify_later(provider: selection.provider, model: selection.model, mode: selection.mode)
    redirect_to @batch, notice: "#{result.rows.size} application PDFs queued - results fill in live."
  end

  def render_ingest_failure(name, errors)
    @batch = Batch.new(name: name)
    @ingest_errors = errors
    @ocr_ready = Extraction::RuntimeDependencies.check_ocr_ready
    render :new, status: :unprocessable_entity
  end

  def ocr_readiness_error(readiness)
    BatchIngest::RowError.new(
      row_number: nil,
      kind: :ocr_unavailable,
      message: readiness.error_message
    )
  end
end
