# frozen_string_literal: true

# Verdicts are always conveyed as text plus glyph plus color - never color
# alone (PRD story 32).
module VerdictsHelper
  VERDICT_PRESENTATION = {
    "pass" => { label: "Passed", glyph: "✓", classes: "bg-pass-tint text-pass" },
    "pass_with_note" => { label: "Passed, with note", glyph: "✓", classes: "bg-pass-tint text-pass" },
    "fail" => { label: "Failed", glyph: "✗", classes: "bg-fail-tint text-fail" },
    "needs_review" => { label: "Needs review", glyph: "◎", classes: "bg-warn-tint text-warn" },
    "not_required" => { label: "Not required", glyph: "–", classes: "bg-panel text-ink-muted" },
    "not_applicable" => { label: "Not applicable", glyph: "–", classes: "bg-panel text-ink-muted" },
    "request_retake" => { label: "Better image needed", glyph: "⚠", classes: "bg-warn-tint text-warn" },
    "error" => { label: "Processing error", glyph: "⚠", classes: "bg-fail-tint text-fail" }
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
