class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  AREAS = {
    reviewer: { label: "Reviewer", classes: "bg-indigo-100 text-indigo-900" },
    pre_review: { label: "Pre-review", classes: "bg-teal-100 text-teal-900" },
    rules: { label: "Rules reference", classes: "bg-stone-200 text-stone-700" }
  }.freeze

  helper_method :current_area

  private

  # Which of the three site areas the current page belongs to; drives the
  # navbar highlight and the per-page area tag. Controllers set @area.
  def current_area
    @area
  end
end
