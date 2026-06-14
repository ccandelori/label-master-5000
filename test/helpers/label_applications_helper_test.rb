# frozen_string_literal: true

require "test_helper"

class LabelApplicationsHelperTest < ActionView::TestCase
  include VerdictsHelper

  def located(text, bbox: [ 10, 20, 100, 12 ], bbox_source: "ocr")
    { "text" => text, "bbox" => bbox, "bbox_source" => bbox_source, "page" => 1, "confidence" => 0.9 }
  end

  def verification(disclosures:, checks: [])
    Verification.new(
      extraction: {
        "image_width" => 800,
        "image_height" => 1000,
        "fields" => {},
        "disclosures" => disclosures
      },
      field_checks: checks
    )
  end

  test "demo model options render the configured refinement model when comparison models are not configured" do
    original = Rails.application.config.x.extraction.demo_models
    Rails.application.config.x.extraction.demo_models = nil

    html = demo_model_options

    assert_includes html, "OCR + gpt-5.4-mini refinement"
    assert_includes html, "openai:gpt-5.4-mini"
    assert_no_match(/quality/, html)
  ensure
    Rails.application.config.x.extraction.demo_models = original
  end

  test "demo model options are OCR-first refinement model choices" do
    html = demo_model_options

    assert_includes html, "OCR + GPT-5.4 nano refinement"
    assert_includes html, "OCR + GPT-5.4 mini refinement"
    assert_includes html, "OCR + Claude Haiku 4.5 refinement"
    assert_includes html, "openai:gpt-5.4-mini"
    assert_includes html, "anthropic:claude-haiku-4-5"
    assert_no_match(/OCR only/, html)
    assert_no_match(/direct comparison/, html)
    assert_no_match(/ocr_only/, html)
    assert_no_match(/ocr_then_vlm/, html)
    assert_no_match(/quality/, html)
  end

  test "demo model label tolerates missing comparison model configuration" do
    original = Rails.application.config.x.extraction.demo_models
    Rails.application.config.x.extraction.demo_models = nil

    assert_equal "ocr-first-v1", demo_model_label("ocr-first-v1")
  ensure
    Rails.application.config.x.extraction.demo_models = original
  end

  test "verification timing lines show OCR and completed refinement durations" do
    v = Verification.new(extraction: {
      "vlm_refinement" => {
        "status" => "complete",
        "model" => "claude-haiku-4-5",
        "duration_ms" => 812.3
      }
    })
    attempt = VerificationAttempt.new(stage_timings: { "ocr_ms" => 2000, "ocr_escalation_ms" => 345.6 })

    assert_equal [ "OCR 2.3s", "Claude Haiku 4.5 refinement 0.8s" ], verification_timing_lines(v, attempt)
  end

  test "verification timing lines show refinement status when no duration exists" do
    v = Verification.new(extraction: {
      "vlm_refinement" => {
        "status" => "pending",
        "model" => "gpt-5.4-mini"
      }
    })

    assert_equal [ "GPT-5.4 mini refinement pending" ], verification_timing_lines(v, nil)
  end

  test "findings groups expose only actionable checks" do
    fail_check = FieldCheck.new(
      field: "brand_name", verdict: "fail", expected: "A", extracted: "B",
      citation: "test", note: "wrong"
    )
    review_check = FieldCheck.new(
      field: "name_and_address", verdict: "needs_review", expected: "A", extracted: nil,
      citation: "test", note: "check"
    )
    pass_check = FieldCheck.new(
      field: "government_warning_text", verdict: "pass_with_note", expected: "A", extracted: "A",
      citation: "test", note: "minor OCR noise"
    )
    not_required_check = FieldCheck.new(
      field: "country_of_origin", verdict: "not_required", expected: nil, extracted: nil,
      citation: "test", note: "domestic"
    )
    v = Verification.new(field_checks: [ pass_check, review_check, not_required_check, fail_check ])

    groups = findings_groups(v)

    assert_equal [ "Failed", "Needs review" ], groups.map { |group| group.fetch(:title) }
    assert_equal [ [ fail_check ], [ review_check ] ], groups.map { |group| group.fetch(:checks) }
    assert_equal 2, quiet_findings_count(v)

    quiet_groups = quiet_findings_groups(v)
    assert_equal [ "Passing", "Informational" ], quiet_groups.map { |group| group.fetch(:title) }
    assert_equal [ [ pass_check ], [ not_required_check ] ], quiet_groups.map { |group| group.fetch(:checks) }
  end

  test "renders one disclosure box per unique normalized text" do
    duplicated = [
      located("CONTAINS SULFITES", bbox: [ 10, 20, 100, 12 ]),
      located("Contains Sulfites.", bbox: [ 10, 800, 100, 12 ])
    ]
    check = FieldCheck.new(
      field: "disclosure_sulfites", verdict: "pass", expected: "CONTAINS SULFITES",
      extracted: "CONTAINS SULFITES", citation: "27 CFR 4.32a", note: nil
    )
    boxes = bbox_data(verification(disclosures: duplicated, checks: [ check ]))

    assert_equal 1, boxes.size
    assert_equal [ 10, 20, 100, 12 ], boxes.first[:bbox], "first occurrence keeps its box"
  end

  test "wires a disclosure box to its matching disclosure check" do
    check = FieldCheck.new(
      field: "disclosure_sulfites", verdict: "fail", expected: "CONTAINS SULFITES",
      extracted: "Contains Sulfites", citation: "27 CFR 4.32a",
      note: "Disclosure must appear in capital letters"
    )
    boxes = bbox_data(verification(disclosures: [ located("Contains Sulfites") ], checks: [ check ]))

    box = boxes.first
    assert_equal "disclosure_sulfites", box[:field]
    assert_equal [ "disclosure_sulfites" ], box[:related_fields]
    assert_equal "fail", box[:verdict]
    assert_equal "Disclosure must appear in capital letters", box[:note]
    assert_equal "27 CFR 4.32a", box[:citation]
    assert_equal "CONTAINS SULFITES", box[:expected]
    assert_equal "Contains Sulfites", box[:extracted]
  end

  test "field boxes carry every check behind the element, worst first" do
    text_fail = FieldCheck.new(
      field: "government_warning_text", verdict: "fail", expected: "GOVERNMENT WARNING: ...",
      extracted: "OVERNMENT WARNING: ...", citation: "27 CFR 16.21", note: "Wording differs"
    )
    prefix_pass = FieldCheck.new(
      field: "government_warning_prefix", verdict: "pass", expected: "GOVERNMENT WARNING",
      extracted: "GOVERNMENT WARNING", citation: "27 CFR 16.22", note: nil
    )
    v = Verification.new(
      extraction: {
        "image_width" => 800, "image_height" => 1000,
        "fields" => { "government_warning" => located("OVERNMENT WARNING: ...") },
        "disclosures" => []
      },
      field_checks: [ prefix_pass, text_fail ]
    )
    box = bbox_data(v).first

    assert_equal %w[government_warning_text government_warning_prefix], box[:checks].map { |c| c[:field] }
    assert_equal "fail", box[:checks].first[:verdict]
    assert_equal "Wording differs", box[:checks].first[:note]
    assert_equal "GOVERNMENT WARNING", box[:checks].last[:expected]
  end

  test "field boxes carry expected and extracted for the popover" do
    check = FieldCheck.new(
      field: "brand_name", verdict: "needs_review", expected: "OLD TOM DISTILLERY",
      extracted: "OLD TOM", citation: "BAM Vol 2 1-1", note: "Differs from the application"
    )
    v = Verification.new(
      extraction: {
        "image_width" => 800, "image_height" => 1000,
        "fields" => { "brand_name" => located("OLD TOM") },
        "disclosures" => []
      },
      field_checks: [ check ]
    )
    box = bbox_data(v).first

    assert_equal "OLD TOM DISTILLERY", box[:expected]
    assert_equal "OLD TOM", box[:extracted]
  end

  test "located fields without a backing check render no box" do
    v = Verification.new(
      extraction: {
        "image_width" => 800, "image_height" => 1000,
        "fields" => { "fanciful_name" => located("LIMITED EDITION, SAME GREAT TASTE") },
        "disclosures" => []
      },
      field_checks: []
    )

    assert_empty bbox_data(v), "nothing on the application means nothing to verify"
  end

  test "disclosure-shaped text no check claimed renders no box" do
    boxes = bbox_data(verification(disclosures: [ located("IA 5c ME 15c"), located("Enjoy responsibly") ]))

    assert_empty boxes, "bottle deposits and taglines are not disclosures"
  end

  test "drops disclosures with malformed boxes" do
    boxes = bbox_data(verification(disclosures: [ located("CONTAINS SULFITES", bbox: [ 1, 2 ]) ]))

    assert_empty boxes
  end

  test "spotlight data only exposes OCR-anchored boxes" do
    check = FieldCheck.new(
      field: "brand_name", verdict: "pass", expected: "OLD TOM",
      extracted: "OLD TOM", citation: "BAM Vol 2 1-1", note: nil
    )
    v = Verification.new(
      extraction: {
        "image_width" => 800, "image_height" => 1000,
        "fields" => { "brand_name" => located("OLD TOM").merge("bbox_source" => "ocr") },
        "disclosures" => []
      },
      field_checks: [ check ]
    )
    assert_equal false, bbox_data(v).first[:approximate]

    v.extraction["fields"]["brand_name"]["bbox_source"] = "model"
    assert_empty bbox_data(v)

    v.extraction["fields"]["brand_name"].delete("bbox_source")
    assert_empty bbox_data(v), "missing provenance is not evidence"
  end

  def application_with_artwork
    app = LabelApplication.new(
      channel: "submitted", serial_number: "26-HLP", beverage_type: "spirits",
      imported: false, brand_name: "OLD TOM", applicant_name_address: "Old Tom Co., Bardstown, KY",
      alcohol_content: 45.0, net_contents: "750 mL"
    )
    app.artwork.attach(io: File.open(Rails.root.join("test/fixtures/files/label.png")),
                       filename: "label.png", content_type: "image/png")
    app.save!
    app
  end

  test "croppable? requires OCR provenance" do
    app = application_with_artwork
    ocr_slot = located("OLD TOM").merge("bbox_source" => "ocr")
    model_slot = located("OLD TOM").merge("bbox_source" => "model")

    assert croppable?(app, ocr_slot)
    assert_not croppable?(app, model_slot)
  end

  test "field_crop_tag clips OCR finds and omits model-only boxes" do
    app = application_with_artwork
    v = Verification.new(extraction: {
      "image_width" => 800, "image_height" => 1000,
      "fields" => { "brand_name" => located("OLD TOM").merge("bbox_source" => "ocr") }
    })

    assert_includes field_crop_tag(app, v, "brand_name"), "<img"

    v.extraction["fields"]["brand_name"]["bbox_source"] = "model"
    assert_nil field_crop_tag(app, v, "brand_name")
  end
end
