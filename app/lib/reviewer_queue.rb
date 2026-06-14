# frozen_string_literal: true

# Pure partitioning and ordering logic for validation history.
module ReviewerQueue
  TABS = %w[needs_attention ready_to_approve failed unchecked decided].freeze
  SORT_KEYS = %w[serial brand beverage_type verdict run_at decision].freeze
  SORT_DIRECTIONS = %w[asc desc].freeze
  DEFAULT_SORT = "run_at"
  DEFAULT_DIRECTION = "desc"

  TAB_LABELS = {
    "needs_attention" => "Needs attention",
    "ready_to_approve" => "Passed",
    "failed" => "Retake",
    "unchecked" => "Unchecked / errors",
    "decided" => "Decided"
  }.freeze

  # Worst-first ordering. Lower rank sorts first.
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
    applications.map { |a| Entry.new(application: a, verification: a.review_verification) }
  end

  # Group entries into the defined tabs, sorted by the selected column
  # within each tab.
  def partition(entries, sort: DEFAULT_SORT, direction: DEFAULT_DIRECTION)
    grouped = entries.group_by { |e| tab_for(e) }
    TABS.index_with { |tab| sort(grouped[tab] || [], sort: sort, direction: direction) }.freeze
  end

  def tab_for(entry)
    v = entry.verification
    return "decided" if v&.decision.present?
    return "unchecked" if v.nil? || v.error?

    case v.overall_verdict
    when "needs_review", "fail"
      "needs_attention"
    when "pass", "pass_with_note"
      "ready_to_approve"
    when "request_retake"
      "failed"
    else
      "unchecked"
    end
  end

  def search(entries, query)
    q = query.to_s.downcase.strip
    return entries if q.blank?
    entries.select do |e|
      app = e.application
      app.serial_number.to_s.downcase.include?(q) ||
        app.brand_name.to_s.downcase.include?(q)
    end
  end

  def filter(entries, filters)
    entries = search(entries, filters[:q])
    entries = match_text(entries, :serial_number, filters[:serial])
    entries = match_text(entries, :brand_name, filters[:brand])
    entries = entries.select { |e| e.application.beverage_type == filters[:beverage_type] } if filters[:beverage_type].present?
    entries = entries.select { |e| verdict_for(e) == filters[:verdict] } if filters[:verdict].present?
    entries
  end

  def sort(entries, sort: DEFAULT_SORT, direction: DEFAULT_DIRECTION)
    sorted = entries.sort_by { |entry| sort_values(entry, sort_key(sort)) }
    sort_direction(direction) == "desc" ? sorted.reverse : sorted
  end

  def sort_key(value)
    SORT_KEYS.include?(value.to_s) ? value.to_s : DEFAULT_SORT
  end

  def sort_direction(value)
    SORT_DIRECTIONS.include?(value.to_s) ? value.to_s : DEFAULT_DIRECTION
  end

  def reviewable?(entry)
    v = entry.verification
    v && !v.error? && v.decision.nil?
  end

  def match_text(entries, attribute, value)
    needle = value.to_s.downcase.strip
    return entries if needle.blank?

    entries.select { |e| e.application.public_send(attribute).to_s.downcase.include?(needle) }
  end

  def sort_values(entry, sort)
    application = entry.application
    verification = entry.verification

    primary = case sort
    when "serial" then application.serial_number.to_s.downcase
    when "brand" then application.brand_name.to_s.downcase
    when "beverage_type" then application.beverage_type.to_s
    when "verdict" then VERDICT_RANK.fetch(verification&.overall_verdict, 99)
    when "decision" then [ verification&.decision.to_s, verification&.decided_at || Time.at(0) ]
    else verification&.created_at || application.created_at || Time.at(0)
    end

    [ primary, application.id ]
  end

  def verdict_for(entry)
    entry.verification&.overall_verdict || "unchecked"
  end
end
