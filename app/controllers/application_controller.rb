class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  AREAS = {
    reviewer: { label: "Reviewer", classes: "bg-focus-tint text-focus" },
    pre_review: { label: "Pre-review", classes: "bg-pass-tint text-pass" },
    rules: { label: "Rules reference", classes: "bg-panel text-ink-muted" }
  }.freeze

  helper_method :current_area

  private

  # Which of the three site areas the current page belongs to; drives the
  # navbar highlight and the per-page area tag. Controllers set @area.
  def current_area
    @area
  end
end
