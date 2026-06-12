# frozen_string_literal: true

class LabelApplicationsController < ApplicationController
  before_action :set_application, only: %i[show edit update]
  before_action :set_area

  def new
    @application = LabelApplication.new
    @stats = verification_stats
  end

  def create
    @application = LabelApplication.new(application_params)

    if @application.save
      provider, model = demo_model_override(@application)
      VerifyLabelJob.perform_later(@application.id, provider, model)
      redirect_to @application, notice: "Label submitted - checking now."
    else
      @stats = verification_stats
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @verification = @application.latest_verification
  end

  def edit
  end

  # Editing application fields re-runs verification against the same
  # artwork; extraction is reused, so re-runs are fast and free.
  def update
    if @application.update(application_params)
      provider, model = demo_model_override(@application)
      VerifyLabelJob.perform_later(@application.id, provider, model)
      redirect_to @application, notice: "Application updated - re-checking against the same artwork."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_application
    @application = LabelApplication.find(params[:id])
  end

  # The form pages are always manufacturer territory; a record's own page
  # follows its channel, so a submitted application reads as reviewer work.
  def set_area
    @area = @application&.submitted? ? :reviewer : :pre_review
  end

  def application_params
    params.expect(label_application: [
      :serial_number, :beverage_type, :imported, :brand_name, :fanciful_name,
      :applicant_name_address, :alcohol_content, :net_contents, :country_of_origin,
      :container_embossed_info, :varietals_list, :appellation, :vintage_year,
      :declared_class_type, :actual_alcohol_content,
      :contains_fd_c_yellow_5, :contains_cochineal_carmine, :contains_sulfites_10ppm,
      :contains_saccharin, :contains_aspartame, :contains_added_coloring,
      :artwork, :back_artwork
    ])
  end

  def verification_stats
    scope = Verification.completed.where.not(latency_ms: nil)
    return nil if scope.none?

    latencies = scope.order(:latency_ms).pluck(:latency_ms)
    {
      count: latencies.size,
      verdicts: Verification.completed.group(:overall_verdict).count,
      average_ms: (latencies.sum.to_f / latencies.size).round,
      p95_ms: latencies[(latencies.size * 0.95).ceil - 1]
    }
  end
end
