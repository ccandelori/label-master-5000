# frozen_string_literal: true

# Immutable value object for one per-field compliance check result.
# Persisted inside Verification#field_checks (jsonb); nothing outside
# this class touches the raw hashes.
class FieldCheck
  VERDICTS = %w[pass pass_with_note fail needs_review not_required not_applicable].freeze

  # Ordering used to derive an overall verdict from a set of checks.
  SEVERITY = {
    "not_applicable" => 0,
    "not_required" => 1,
    "pass" => 2,
    "pass_with_note" => 3,
    "needs_review" => 4,
    "fail" => 5
  }.freeze

  attr_reader :field, :verdict, :expected, :extracted, :citation, :note

  def initialize(field:, verdict:, expected:, extracted:, citation:, note:)
    raise ArgumentError, "unknown verdict: #{verdict.inspect}" unless VERDICTS.include?(verdict)
    raise ArgumentError, "field must be present" if field.to_s.empty?

    @field = field.to_s
    @verdict = verdict
    @expected = expected
    @extracted = extracted
    @citation = citation
    @note = note
    freeze
  end

  def self.from_h(hash)
    h = hash.transform_keys(&:to_s)
    new(
      field: h.fetch("field"),
      verdict: h.fetch("verdict"),
      expected: h["expected"],
      extracted: h["extracted"],
      citation: h["citation"],
      note: h["note"]
    )
  end

  def to_h
    {
      "field" => field,
      "verdict" => verdict,
      "expected" => expected,
      "extracted" => extracted,
      "citation" => citation,
      "note" => note
    }
  end

  def severity
    SEVERITY.fetch(verdict)
  end

  def ==(other)
    other.is_a?(FieldCheck) && to_h == other.to_h
  end
  alias eql? ==

  def hash
    to_h.hash
  end

  # Overall verdict for a verification, derived from its field checks.
  # Informational verdicts (not_required, not_applicable) never drag the
  # overall result below pass.
  def self.overall(checks)
    raise ArgumentError, "checks must not be empty" if checks.empty?

    worst = checks.max_by(&:severity)
    case worst.verdict
    when "fail", "needs_review", "pass_with_note" then worst.verdict
    else "pass"
    end
  end
end
