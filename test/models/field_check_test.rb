# frozen_string_literal: true

require "test_helper"

class FieldCheckTest < ActiveSupport::TestCase
  def build_check(verdict:)
    FieldCheck.new(
      field: "brand_name",
      verdict: verdict,
      expected: "OLD TOM DISTILLERY",
      extracted: "Old Tom Distillery",
      citation: "BAM Vol 2, 1-1",
      note: nil
    )
  end

  test "rejects unknown verdicts" do
    assert_raises(ArgumentError) { build_check(verdict: "maybe") }
  end

  test "rejects blank field" do
    assert_raises(ArgumentError) do
      FieldCheck.new(field: "", verdict: "pass", expected: nil, extracted: nil, citation: nil, note: nil)
    end
  end

  test "round-trips through hash representation" do
    check = build_check(verdict: "pass_with_note")
    assert_equal check, FieldCheck.from_h(check.to_h)
    assert_equal check, FieldCheck.from_h(check.to_h.transform_keys(&:to_sym))
  end

  test "is frozen" do
    assert build_check(verdict: "pass").frozen?
  end

  test "overall verdict is the worst field verdict" do
    checks = %w[pass pass_with_note fail needs_review].map { |v| build_check(verdict: v) }
    assert_equal "fail", FieldCheck.overall(checks)
  end

  test "needs_review outranks pass_with_note" do
    checks = %w[pass_with_note needs_review pass].map { |v| build_check(verdict: v) }
    assert_equal "needs_review", FieldCheck.overall(checks)
  end

  test "informational verdicts roll up to pass" do
    checks = %w[not_required not_applicable].map { |v| build_check(verdict: v) }
    assert_equal "pass", FieldCheck.overall(checks)
  end

  test "all pass rolls up to pass" do
    checks = %w[pass pass not_required].map { |v| build_check(verdict: v) }
    assert_equal "pass", FieldCheck.overall(checks)
  end

  test "overall requires at least one check" do
    assert_raises(ArgumentError) { FieldCheck.overall([]) }
  end
end
