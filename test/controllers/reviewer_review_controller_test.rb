# frozen_string_literal: true

require "test_helper"

class ReviewerReviewControllerTest < ActionDispatch::IntegrationTest
  def create_application(serial:, brand:, channel: "submitted")
    LabelApplication.create!(
      channel: channel,
      serial_number: serial,
      brand_name: brand,
      beverage_type: "spirits",
      applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
      alcohol_content: 45,
      net_contents: "750 mL"
    )
  end

  def add_verification(application, verdict:, decision: nil)
    application.verifications.create!(
      overall_verdict: verdict,
      decision: decision,
      decided_at: decision ? Time.current : nil,
      field_checks: [
        { field: "brand_name", verdict: "pass", expected: application.brand_name,
          extracted: application.brand_name, citation: nil, note: nil },
        { field: "government_warning_prefix", verdict: "fail", expected: "GOVERNMENT WARNING",
          extracted: "Government Warning", citation: "27 CFR 16.22",
          note: "GOVERNMENT WARNING must appear in capital letters" }
      ],
      extraction: {
        "fields" => {
          "brand_name" => { "text" => application.brand_name, "bbox" => [ 10, 10, 100, 20 ], "page" => 1 },
          "government_warning" => { "text" => "Government Warning: ...", "bbox" => [ 10, 120, 220, 30 ], "page" => 1 }
        }
      }
    )
  end

  test "payload boxes carry provenance for the approximate treatment" do
    application = create_application(serial: "26-PROV", brand: "OLD TOM")
    application.verifications.create!(
      overall_verdict: "needs_review",
      field_checks: [
        { field: "brand_name", verdict: "pass", expected: "OLD TOM",
          extracted: "OLD TOM", citation: nil, note: nil },
        { field: "net_contents", verdict: "needs_review", expected: "750 mL",
          extracted: "750mL", citation: "27 CFR 5.70", note: "Differs" }
      ],
      extraction: {
        "fields" => {
          "brand_name" => { "text" => "OLD TOM", "bbox" => [ 10, 10, 100, 20 ],
                            "bbox_source" => "ocr", "bbox_basis" => [ 800, 1000 ], "page" => 1 },
          "net_contents" => { "text" => "750mL", "bbox" => [ 10, 120, 80, 16 ],
                              "bbox_source" => "model", "page" => 1 }
        }
      }
    )

    get reviewer_review_next_path
    payload = response.parsed_body

    located = payload["boxes"].find { |b| b["field"] == "brand_name" }
    estimated = payload["boxes"].find { |b| b["field"] == "net_contents" }
    assert_equal false, located["approximate"]
    assert_equal true, estimated["approximate"]
    assert_nil estimated["crop_url"], "an estimate never offers an evidence crop"
  end

  test "the shell embeds the first undecided item, worst first" do
    passing = create_application(serial: "26-PASS", brand: "CLEAN GIN")
    add_verification(passing, verdict: "pass")
    failing = create_application(serial: "26-FAIL", brand: "BAD BOURBON")
    add_verification(failing, verdict: "needs_review")

    get reviewer_review_path
    assert_response :success
    assert_match(/26-FAIL/, response.body)
    assert_match(/Exit review mode/, response.body)
  end

  test "next_item returns the callout payload" do
    application = create_application(serial: "26-1", brand: "OLD TOM")
    add_verification(application, verdict: "needs_review")

    get reviewer_review_next_path
    assert_response :success
    payload = response.parsed_body

    assert_equal "26-1", payload.dig("application", "serial_number")
    assert_equal "needs_review", payload.dig("verification", "overall_verdict")
    assert_equal 1, payload.dig("summary", "fails")
    assert_equal 1, payload["remaining"]
    assert_equal label_application_decision_path(application), payload["decision_path"]

    warning_box = payload["boxes"].find { |b| b["label"] == "Government warning" }
    assert_equal "fail", warning_box["verdict"]
    assert_equal "27 CFR 16.22", warning_box["citation"]
    assert_equal [ 10, 120, 220, 30 ], warning_box["bbox"]

    finding = payload["findings"].first
    assert_equal "fail", finding["verdict"]
    assert_match(/capital letters/, finding["note"])
    assert_equal "GOVERNMENT WARNING", finding["expected"]
    assert_equal "Government Warning", finding["extracted"]
    assert_nil payload["back_artwork_url"], "no back label, no back url"
  end

  test "the payload carries the back label url when one is attached" do
    application = create_application(serial: "26-2S", brand: "TWO SIDED")
    application.artwork.attach(io: StringIO.new("front"), filename: "front.png", content_type: "image/png")
    application.back_artwork.attach(io: StringIO.new("back"), filename: "back.png", content_type: "image/png")
    application.save!
    add_verification(application, verdict: "needs_review")

    get reviewer_review_next_path
    payload = response.parsed_body

    assert payload["artwork_url"].present?
    assert payload["back_artwork_url"].present?
    assert_not_equal payload["artwork_url"], payload["back_artwork_url"]
  end

  test "start pins the opening item regardless of severity order" do
    failing = create_application(serial: "26-WORST", brand: "WORST FIRST")
    add_verification(failing, verdict: "needs_review")
    passing = create_application(serial: "26-PINNED", brand: "PINNED PASS")
    add_verification(passing, verdict: "pass")

    get reviewer_review_path(start: passing.id)
    assert_response :success
    assert_match(/26-PINNED/, response.body)

    # An unknown or unreviewable start falls back to worst-first.
    get reviewer_review_path(start: 999_999)
    assert_match(/26-WORST/, response.body)
  end

  test "next_item skips deferred ids and decided or pre-review records" do
    first = create_application(serial: "26-1", brand: "FIRST")
    add_verification(first, verdict: "needs_review")
    second = create_application(serial: "26-2", brand: "SECOND")
    add_verification(second, verdict: "needs_review")
    decided = create_application(serial: "26-3", brand: "DECIDED")
    add_verification(decided, verdict: "fail", decision: "reject")
    sandbox = create_application(serial: "26-4", brand: "SANDBOX", channel: "pre_review")
    add_verification(sandbox, verdict: "needs_review")

    get reviewer_review_next_path(skip: first.id.to_s)
    assert_equal "26-2", response.parsed_body.dig("application", "serial_number")

    get reviewer_review_next_path(skip: [ first.id, second.id ].join(","))
    assert response.parsed_body["done"]
  end

  test "a decision removes the item from the review feed" do
    application = create_application(serial: "26-1", brand: "OLD TOM")
    verification = add_verification(application, verdict: "needs_review")

    post label_application_decision_path(application), as: :json,
         params: { decision: { verification_id: verification.id, decision: "reject" } }
    assert_response :success
    assert response.parsed_body["ok"]

    get reviewer_review_next_path
    assert response.parsed_body["done"]
  end

  test "undo returns the item to the review feed" do
    application = create_application(serial: "26-1", brand: "OLD TOM")
    verification = add_verification(application, verdict: "needs_review")
    verification.record_decision(decision: "reject", note: nil)

    delete label_application_decision_path(application), as: :json,
           params: { verification_id: verification.id }
    assert_response :success
    assert_nil verification.reload.decision

    get reviewer_review_next_path
    assert_equal "26-1", response.parsed_body.dig("application", "serial_number")
  end

  test "an empty feed renders the queue-clear state" do
    get reviewer_review_path
    assert_response :success
    assert_match(/Queue clear/, response.body)
  end
end
