# frozen_string_literal: true

# Verdicts are always conveyed as text plus glyph plus color - never color
# alone (PRD story 32).
module VerdictsHelper
  VERDICT_PRESENTATION = {
    "pass" => { label: "Passed", glyph: "✓", classes: "bg-green-100 text-green-900" },
    "pass_with_note" => { label: "Passed, with note", glyph: "✓", classes: "bg-teal-100 text-teal-900" },
    "fail" => { label: "Failed", glyph: "✗", classes: "bg-red-100 text-red-900" },
    "needs_review" => { label: "Needs review", glyph: "◎", classes: "bg-amber-100 text-amber-900" },
    "not_required" => { label: "Not required", glyph: "–", classes: "bg-gray-100 text-gray-700" },
    "not_applicable" => { label: "Not applicable", glyph: "–", classes: "bg-gray-100 text-gray-700" },
    "request_retake" => { label: "Better image needed", glyph: "⚠", classes: "bg-amber-100 text-amber-900" },
    "error" => { label: "Processing error", glyph: "⚠", classes: "bg-red-100 text-red-900" }
  }.freeze

  def verdict_chip(verdict)
    presentation = VERDICT_PRESENTATION.fetch(verdict)
    tag.span(class: "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-sm font-medium whitespace-nowrap #{presentation[:classes]}") do
      safe_join([ tag.span(presentation[:glyph], "aria-hidden": true), presentation[:label] ], " ")
    end
  end

  def verdict_label(verdict)
    VERDICT_PRESENTATION.fetch(verdict)[:label]
  end

  def field_label(field)
    field.to_s.humanize.sub("Fd c", "FD&C").sub("Abv", "ABV")
  end
end
