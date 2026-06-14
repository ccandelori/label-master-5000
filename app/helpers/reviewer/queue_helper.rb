# frozen_string_literal: true

module Reviewer::QueueHelper
  def history_params(overrides = {})
    {
      tab: @tab,
      q: @filters[:q].presence,
      serial: @filters[:serial].presence,
      brand: @filters[:brand].presence,
      beverage_type: @filters[:beverage_type].presence,
      verdict: @filters[:verdict].presence,
      sort: @sort,
      direction: @direction
    }.merge(overrides).compact
  end

  def sortable_history_header(label, sort)
    active = @sort == sort.to_s
    next_direction = active && @direction == "asc" ? "desc" : "asc"
    arrow = active ? (@direction == "asc" ? "↑" : "↓") : "↕"

    link_to validation_history_path(history_params(sort: sort, direction: next_direction)),
            class: "inline-flex items-center gap-1 font-medium hover:text-ink" do
      safe_join([ label, tag.span(arrow, class: active ? "text-ink" : "text-ink-faint", "aria-hidden": true) ], " ")
    end
  end

  def history_aria_sort(sort)
    return "none" unless @sort == sort.to_s

    @direction == "asc" ? "ascending" : "descending"
  end

  def history_result_options
    [
      [ "Any result", "" ],
      [ "Unchecked", "unchecked" ],
      [ "Needs review", "needs_review" ],
      [ "Failed", "fail" ],
      [ "Better image needed", "request_retake" ],
      [ "Processing error", "error" ],
      [ "Passed", "pass" ],
      [ "Passed, with note", "pass_with_note" ]
    ]
  end
end
