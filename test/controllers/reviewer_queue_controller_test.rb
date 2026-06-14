# frozen_string_literal: true

require "test_helper"

class ReviewerQueueControllerTest < ActionDispatch::IntegrationTest
  def create_application(channel:, serial:, brand: "BRAND #{rand(1000)}", source_kind: "manual")
    LabelApplication.create!(
      channel: channel,
      source_kind: source_kind,
      serial_number: serial,
      brand_name: brand,
      beverage_type: "malt",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz"
    )
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

  test "history lists validation and submitted applications" do
    create_application(channel: "submitted", serial: "SUB-1").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "pre_review", serial: "PRE-1").tap { |a| add_verification(a, verdict: "needs_review") }

    get validation_history_path
    assert_response :success
    assert_match(/SUB-1/, response.body)
    assert_match(/PRE-1/, response.body)
  end

  test "history hides non-validation templates and quarantined submissions" do
    create_application(channel: "submitted", serial: "REAL-1", source_kind: "batch_upload")
      .tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "EVAL-1", source_kind: "registry_eval")
      .tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "MUT-1", source_kind: "mutation")
      .tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "pre_review", serial: "SAMPLE-1", source_kind: "seed_application_pdf")
      .tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "QUAR-1", source_kind: "manual")
      .tap do |application|
        add_verification(application, verdict: "needs_review")
        application.quarantine!(reasons: [ "primary_artwork_filename_indicates_back" ])
      end

    get validation_history_path
    assert_response :success
    assert_match(/REAL-1/, response.body)
    assert_no_match(/EVAL-1/, response.body)
    assert_no_match(/MUT-1/, response.body)
    assert_no_match(/SAMPLE-1/, response.body)
    assert_no_match(/QUAR-1/, response.body)
  end

  test "validation is the application root" do
    get root_path
    assert_response :success
    assert_match(/Validate a label application/, response.body)
    assert_no_match(/Reviewer/, response.body)
  end

  test "history subscribes to the live stream and morphs on refresh" do
    get validation_history_path
    assert_response :success
    assert_select "turbo-cable-stream-source[signed-stream-name=?]",
                  Turbo::StreamsChannel.signed_stream_name(:validation_history)
    assert_select "meta[name=turbo-refresh-method][content=morph]"
    assert_select "meta[name=turbo-refresh-scroll][content=preserve]"
    assert_select "input#queue_search_q[data-turbo-permanent]"
  end

  test "tabs partition the queue by work state" do
    create_application(channel: "submitted", serial: "REVIEW-1").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "FAIL-1").tap { |a| add_verification(a, verdict: "fail") }
    create_application(channel: "submitted", serial: "PASS-1").tap { |a| add_verification(a, verdict: "pass") }
    create_application(channel: "submitted", serial: "PEND-1")
    create_application(channel: "submitted", serial: "DONE-1").tap { |a| add_verification(a, verdict: "pass", decision: "approve") }

    get validation_history_path
    assert_match(/REVIEW-1/, response.body)
    assert_match(/FAIL-1/, response.body)
    assert_no_match(/PASS-1/, response.body)

    get validation_history_path(tab: "failed")
    assert_no_match(/FAIL-1/, response.body)
    assert_no_match(/REVIEW-1/, response.body)

    get validation_history_path(tab: "ready_to_approve")
    assert_match(/PASS-1/, response.body)
    assert_no_match(/FAIL-1/, response.body)

    get validation_history_path(tab: "unchecked")
    assert_match(/PEND-1/, response.body)

    get validation_history_path(tab: "decided")
    assert_match(/DONE-1/, response.body)
    assert_match(/Approve/, response.body)
  end

  test "queue row navigation opens the application details workspace" do
    application = create_application(channel: "submitted", serial: "DETAILS-1")
    add_verification(application, verdict: "needs_review")

    get validation_history_path
    assert_response :success
    assert_select "a[href=?]", label_application_path(application, anchor: "check_workspace"), text: "Details", count: 1
    assert_no_match(%r{/reviewer/review}, response.body)
    assert_no_match(/Enter review mode/, response.body)
  end

  test "history defaults to most recent run first" do
    create_application(channel: "submitted", serial: "OLD-1").tap do |application|
      add_verification(application, verdict: "fail", created_at: 2.hours.ago)
    end
    create_application(channel: "submitted", serial: "NEW-1").tap do |application|
      add_verification(application, verdict: "needs_review", created_at: 1.minute.ago)
    end

    get validation_history_path
    assert_operator response.body.index("NEW-1"), :<, response.body.index("OLD-1")
    assert_select "th[aria-sort=descending]", text: /Run/
  end

  test "history can sort by a column" do
    create_application(channel: "submitted", serial: "B-2", brand: "ZED").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "A-1", brand: "ALPHA").tap { |a| add_verification(a, verdict: "needs_review") }

    get validation_history_path(sort: "brand", direction: "asc")

    assert_operator response.body.index("ALPHA"), :<, response.body.index("ZED")
    assert_select "th[aria-sort=ascending]", text: /Brand/
  end

  test "search narrows by serial or brand" do
    create_application(channel: "submitted", serial: "FIND-ME", brand: "ALPHA").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "OTHER-1", brand: "BETA").tap { |a| add_verification(a, verdict: "needs_review") }

    get validation_history_path(q: "find")
    assert_match(/FIND-ME/, response.body)
    assert_no_match(/OTHER-1/, response.body)
  end

  test "history filters by column values" do
    create_application(channel: "submitted", serial: "MATCH-1", brand: "ALPHA").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "MISS-1", brand: "BETA").tap { |a| add_verification(a, verdict: "needs_review") }
    create_application(channel: "submitted", serial: "MATCH-2", brand: "ALPHA").tap { |a| add_verification(a, verdict: "pass") }

    get validation_history_path(brand: "alpha", verdict: "needs_review")

    assert_match(/MATCH-1/, response.body)
    assert_no_match(/MISS-1/, response.body)
    assert_no_match(/MATCH-2/, response.body)
    assert_select "input[name=brand][value=alpha]"
    assert_select "select[name=verdict] option[value=needs_review][selected=selected]"
  end

  test "one-click approve decides a clean pass and returns to the queue" do
    application = create_application(channel: "submitted", serial: "CLEAN-1")
    verification = add_verification(application, verdict: "pass")

    get validation_history_path(tab: "ready_to_approve")
    assert_match(/CLEAN-1/, response.body)

    post label_application_decision_path(application),
         params: { decision: { verification_id: verification.id, decision: "approve" } },
         headers: { "HTTP_REFERER" => validation_history_path(tab: "ready_to_approve") }

    assert_redirected_to validation_history_path(tab: "ready_to_approve")
    assert_equal "approve", verification.reload.decision
  end

  test "an empty tab says so" do
    get validation_history_path
    assert_match(/Nothing in needs attention/, response.body)
  end

  test "standalone reviewer mode is not routable" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/reviewer/review")
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/reviewer/review/next")
    end
  end
end
