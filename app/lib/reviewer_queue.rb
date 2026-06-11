# frozen_string_literal: true

# Pure partitioning and ordering logic for the reviewer queue. Works over
# in-memory (application, latest verification) pairs - queue sizes are a
# day's filings, not a data warehouse.
module ReviewerQueue
  TABS = %w[needs_attention ready_to_approve failed unchecked decided].freeze

  TAB_LABELS = {
    "needs_attention" => "Needs attention",
    "ready_to_approve" => "Ready to approve",
    "failed" => "Failed",
    "unchecked" => "Unchecked / errors",
    "decided" => "Decided"
  }.freeze

  # Worst-first ordering. Lower rank sorts first; unchecked records have no
  # verdict and sort last within their tab.
  VERDICT_RANK = {
    "fail" => 0,
    "needs_review" => 1,
    "request_retake" => 2,
    "error" => 3,
    "pass_with_note" => 4,
    "pass" => 5
  }.freeze

  Entry = Data.define(:application, :verification)

  module_function

  def entries(applications)
    applications.map { |a| Entry.new(application: a, verification: a.latest_verification) }
  end

  def tab_for(entry)
    verification = entry.verification
    return "decided" if verification&.decision.present?
    return "unchecked" if verification.nil? || verification.error?

    case verification.overall_verdict
    when "pass", "pass_with_note" then "ready_to_approve"
    # A failed check is a finding, not a judgment call: failed labels
    # await rejection, they do not compete for review attention.
    when "fail" then "failed"
    else "needs_attention"
    end
  end

  # Review mode walks every undecided label a human still acts on:
  # needs-review findings, clean passes awaiting approval, and failed
  # labels awaiting their rejection - a reviewer confirms a failure in
  # context rather than rubber-stamping it from a list.
  def reviewable?(entry)
    %w[needs_attention ready_to_approve failed].include?(tab_for(entry))
  end

  def partition(entries)
    grouped = entries.group_by { |e| tab_for(e) }
    TABS.index_with { |tab| sort(grouped.fetch(tab, [])) }
  end

  def search(entries, query)
    needle = query.downcase
    entries.select do |e|
      e.application.serial_number.to_s.downcase.include?(needle) ||
        e.application.brand_name.to_s.downcase.include?(needle)
    end
  end

  # Worst verdict first, then oldest first.
  def sort(entries)
    entries.sort_by do |e|
      [ VERDICT_RANK.fetch(e.verification&.overall_verdict, VERDICT_RANK.size), e.application.created_at ]
    end
  end
end
