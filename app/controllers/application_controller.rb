class ApplicationController < ActionController::Base
  ValidationModeSelection = Data.define(:provider, :model, :mode)

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  helper_method :current_area

  private

  # Which site area the current page belongs to; drives the
  # navbar highlight and the per-page area tag. Controllers set @area.
  def current_area
    @area
  end

  # The validation demo's per-run refinement choice. Pre-review records run
  # OCR first, then refine unresolved findings with the selected VLM. Filed
  # records ignore this affordance.
  def validation_mode_selection(application)
    return default_validation_mode_selection unless application.pre_review?

    selected_pre_review_validation_mode
  end

  def selected_pre_review_validation_mode
    selected = params[:demo_model].to_s
    return configured_refinement_mode_selection if selected.blank? || selected == "quality"

    provider, model = selected.split(":", 2)
    entry = refinement_model_entry(provider: provider, model: model)
    return configured_refinement_mode_selection unless entry

    ValidationModeSelection.new(
      provider: entry.fetch("provider"),
      model: entry.fetch("model"),
      mode: VerifyLabelJob::OCR_THEN_VLM_MODE
    )
  end

  def refinement_model_entry(provider:, model:)
    return nil if provider.blank? || model.blank?

    configured = configured_refinement_entry
    return configured if configured["provider"] == provider && configured["model"] == model

    Array(Rails.application.config.x.extraction.demo_models)
      .find { |entry| entry["provider"] == provider && entry["model"] == model }
  end

  def configured_refinement_mode_selection
    entry = configured_refinement_entry
    ValidationModeSelection.new(
      provider: entry.fetch("provider"),
      model: entry.fetch("model"),
      mode: VerifyLabelJob::OCR_THEN_VLM_MODE
    )
  end

  def configured_refinement_entry
    config = Rails.application.config.x.extraction
    {
      "provider" => config.provider,
      "model" => config.model,
      "label" => config.model
    }
  end

  def default_validation_mode_selection
    ValidationModeSelection.new(provider: nil, model: nil, mode: nil)
  end
end
