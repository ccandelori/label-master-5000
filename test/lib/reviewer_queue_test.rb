# frozen_string_literal: true

require "test_helper"

class ReviewerQueueTest < ActiveSupport::TestCase
  def create_application(serial:, brand: "BRAND", created_at: Time.current)
    LabelApplication.create!(
      channel: "submitted",
      serial_number: serial,
      brand_name: brand,
      beverage_type: "malt",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz",
      created_at: created_at
    )
  end

  def entry_for(application)
    ReviewerQueue::Entry.new(application: application, verification: application.latest_verification)
  end

  def add_verification(application, verdict:, decision: nil, created_at: Time.current)
    application.verifications.create!(
      overall_verdict: verdict,
      field_checks: [],
      decision: decision,
      decided_at: decision ? Time.current : nil,
      created_at: created_at
    )
  end

  test "tab_for routes each state to its tab" do
    unchecked = create_application(serial: "T-1")
    errored = create_application(serial: "T-2").tap { |a| add_verification(a, verdict: "error") }
    failing = create_application(serial: "T-3").tap { |a| add_verification(a, verdict: "fail") }
    retake = create_application(serial: "T-4").tap { |a| add_verification(a, verdict: "request_retake") }
    passing = create_application(serial: "T-5").tap { |a| add_verification(a, verdict: "pass") }
    decided = create_application(serial: "T-6").tap { |a| add_verification(a, verdict: "pass", decision: "approve") }

    assert_equal "unchecked", ReviewerQueue.tab_for(entry_for(unchecked))
    assert_equal "unchecked", ReviewerQueue.tab_for(entry_for(errored))
    assert_equal "needs_attention", ReviewerQueue.tab_for(entry_for(failing))
    assert_equal "failed", ReviewerQueue.tab_for(entry_for(retake))
    assert_equal "ready_to_approve", ReviewerQueue.tab_for(entry_for(passing))
    assert_equal "decided", ReviewerQueue.tab_for(entry_for(decided))
  end

  test "default sort puts newest runs first" do
    old_pass = create_application(serial: "S-1").tap { |a| add_verification(a, verdict: "pass", created_at: 3.hours.ago) }
    new_fail = create_application(serial: "S-2").tap { |a| add_verification(a, verdict: "fail", created_at: 1.minute.ago) }
    old_fail = create_application(serial: "S-3").tap { |a| add_verification(a, verdict: "fail", created_at: 1.hour.ago) }
    review = create_application(serial: "S-4").tap { |a| add_verification(a, verdict: "needs_review", created_at: 2.hours.ago) }

    sorted = ReviewerQueue.sort([ old_pass, new_fail, old_fail, review ].map { |a| entry_for(a) })
    assert_equal %w[S-2 S-3 S-4 S-1], sorted.map { |e| e.application.serial_number }
  end

  test "sort can use a selected column and direction" do
    zed = create_application(serial: "S-1", brand: "ZED").tap { |a| add_verification(a, verdict: "pass") }
    alpha = create_application(serial: "S-2", brand: "ALPHA").tap { |a| add_verification(a, verdict: "fail") }

    entries = [ zed, alpha ].map { |application| entry_for(application) }

    assert_equal %w[S-2 S-1], ReviewerQueue.sort(entries, sort: "brand", direction: "asc").map { |e| e.application.serial_number }
    assert_equal %w[S-1 S-2], ReviewerQueue.sort(entries, sort: "brand", direction: "desc").map { |e| e.application.serial_number }
  end

  test "search matches serial and brand, case-insensitively" do
    match_serial = create_application(serial: "26-ABC", brand: "PLAIN")
    match_brand = create_application(serial: "26-2", brand: "Stone's Throw")
    miss = create_application(serial: "26-3", brand: "OTHER")

    entries = [ match_serial, match_brand, miss ].map { |a| entry_for(a) }
    assert_equal [ "26-ABC" ], ReviewerQueue.search(entries, "abc").map { |e| e.application.serial_number }
    assert_equal [ "26-2" ], ReviewerQueue.search(entries, "stone").map { |e| e.application.serial_number }
  end

  test "filter narrows by column values" do
    match = create_application(serial: "26-MATCH", brand: "ALPHA")
    add_verification(match, verdict: "pass")
    other_brand = create_application(serial: "26-MISS", brand: "BETA")
    add_verification(other_brand, verdict: "pass")
    other_verdict = create_application(serial: "26-OTHER", brand: "ALPHA")
    add_verification(other_verdict, verdict: "fail")

    entries = [ match, other_brand, other_verdict ].map { |application| entry_for(application) }
    filtered = ReviewerQueue.filter(entries, brand: "alpha", verdict: "pass")

    assert_equal [ "26-MATCH" ], filtered.map { |e| e.application.serial_number }
  end

  test "reviewable covers every undecided label a human acts on, including failed" do
    needs_review = create_application(serial: "R-0").tap { |a| add_verification(a, verdict: "needs_review") }
    failing = create_application(serial: "R-1").tap { |a| add_verification(a, verdict: "fail") }
    unchecked = create_application(serial: "R-2")
    decided = create_application(serial: "R-3").tap { |a| add_verification(a, verdict: "fail", decision: "reject") }

    assert ReviewerQueue.reviewable?(entry_for(needs_review))
    assert ReviewerQueue.reviewable?(entry_for(failing)), "a failure is confirmed in review, not rubber-stamped from a list"
    assert_not ReviewerQueue.reviewable?(entry_for(unchecked))
    assert_not ReviewerQueue.reviewable?(entry_for(decided))
  end
end
