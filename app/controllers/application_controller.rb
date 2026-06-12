class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  AREAS = {
    reviewer: { label: "Reviewer", classes: "bg-focus-tint text-focus" },
    pre_review: { label: "Pre-check", classes: "bg-pass-tint text-pass" },
    rules: { label: "Rules reference", classes: "bg-panel text-ink-muted" }
  }.freeze

  helper_method :current_area

  private

  # Which of the three site areas the current page belongs to; drives the
  # navbar highlight and the per-page area tag. Controllers set @area.
  def current_area
    @area
  end

  # The pre-review demo's per-run model choice ("provider:model" from the
  # configured menu). Returns [provider, model] or [nil, nil]; anything
  # not on the menu, or any non-pre-review application, runs the default -
  # the demo affordance must never steer reviewer-channel work.
  def demo_model_override(application)
    return [ nil, nil ] unless application.pre_review? && params[:demo_model].present?

    provider, model = params[:demo_model].split(":", 2)
    entry = Rails.application.config.x.extraction.demo_models
                 .find { |e| e["provider"] == provider && e["model"] == model }
    entry ? [ entry["provider"], entry["model"] ] : [ nil, nil ]
  end
end
