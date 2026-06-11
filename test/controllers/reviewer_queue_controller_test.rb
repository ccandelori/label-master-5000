# frozen_string_literal: true

require "test_helper"

class ReviewerQueueControllerTest < ActionDispatch::IntegrationTest
  def create_application(channel:, serial:, brand: "BRAND #{rand(1000)}")
    LabelApplication.create!(
      channel: channel,
      serial_number: serial,
      brand_name: brand,
      beverage_type: "malt",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
  end

  def add_verification(application, verdict:, decision: nil)
    application.verifications.create!(
      overall_verdict: verdict,
      field_checks: [],
      decision: decision,
      decided_at: decision ? Time.current : nil
    )
  end

  test "the queue lists submitted applications only" do
    create_application(channel: "submitted", serial: "SUB-1").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "pre_review", serial: "PRE-1").tap { |a| add_verification(a, verdict: "needs_review") }

    get reviewer_queue_path
    assert_response :success
    assert_match(/SUB-1/, response.body)
    assert_no_match(/PRE-1/, response.body)
  end

  test "the queue is the application root" do
    get root_path
    assert_response :success
    assert_match(/Review queue/, response.body)
  end

  test "tabs partition the queue by work state" do
    create_application(channel: "submitted", serial: "REVIEW-1").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "FAIL-1").tap { |a| add_verification(a, verdict: "fail") }
    create_application(channel: "submitted", serial: "PASS-1").tap { |a| add_verification(a, verdict: "pass") }
    create_application(channel: "submitted", serial: "PEND-1")
    create_application(channel: "submitted", serial: "DONE-1").tap { |a| add_verification(a, verdict: "pass", decision: "approve") }

    get reviewer_queue_path
    assert_match(/REVIEW-1/, response.body)
    assert_no_match(/FAIL-1/, response.body)
    assert_no_match(/PASS-1/, response.body)

    get reviewer_queue_path(tab: "failed")
    assert_match(/FAIL-1/, response.body)
    assert_match(/Reject/, response.body)
    assert_no_match(/REVIEW-1/, response.body)

    get reviewer_queue_path(tab: "ready_to_approve")
    assert_match(/PASS-1/, response.body)
    assert_no_match(/FAIL-1/, response.body)

    get reviewer_queue_path(tab: "unchecked")
    assert_match(/PEND-1/, response.body)

    get reviewer_queue_path(tab: "decided")
    assert_match(/DONE-1/, response.body)
    assert_match(/Approve/, response.body)
  end

  test "needs attention orders worst verdict first" do
    create_application(channel: "submitted", serial: "RETAKE-1").tap { |a| add_verification(a, verdict: "request_retake") }
    create_application(channel: "submitted", serial: "REVIEW-1").tap { |a| add_verification(a, verdict: "needs_review") }

    get reviewer_queue_path
    assert_operator response.body.index("REVIEW-1"), :<, response.body.index("RETAKE-1")
  end

  test "search narrows by serial or brand" do
    create_application(channel: "submitted", serial: "FIND-ME", brand: "ALPHA").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "OTHER-1", brand: "BETA").tap { |a| add_verification(a, verdict: "needs_review") }

    get reviewer_queue_path(q: "find")
    assert_match(/FIND-ME/, response.body)
    assert_no_match(/OTHER-1/, response.body)
  end

  test "one-click approve decides a clean pass and returns to the queue" do
    application = create_application(channel: "submitted", serial: "CLEAN-1")
    verification = add_verification(application, verdict: "pass")

    get reviewer_queue_path(tab: "ready_to_approve")
    assert_match(/CLEAN-1/, response.body)

    post label_application_decision_path(application),
         params: { decision: { verification_id: verification.id, decision: "approve" } },
         headers: { "HTTP_REFERER" => reviewer_queue_path(tab: "ready_to_approve") }

    assert_redirected_to reviewer_queue_path(tab: "ready_to_approve")
    assert_equal "approve", verification.reload.decision
  end

  test "an empty tab says so" do
    get reviewer_queue_path
    assert_match(/Nothing in needs attention/, response.body)
  end
end
