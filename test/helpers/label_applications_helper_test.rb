# frozen_string_literal: true

require "test_helper"

class LabelApplicationsHelperTest < ActionView::TestCase
  include VerdictsHelper

  def located(text, bbox: [ 10, 20, 100, 12 ])
    { "text" => text, "bbox" => bbox, "page" => 1, "confidence" => 0.9 }
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

  test "renders one disclosure box per unique normalized text" do
    duplicated = [
      located("CONTAINS SULFITES", bbox: [ 10, 20, 100, 12 ]),
      located("Contains Sulfites.", bbox: [ 10, 800, 100, 12 ]),
      located("COLORED WITH FD&C YELLOW #5", bbox: [ 10, 400, 100, 12 ])
    ]
    boxes = bbox_data(verification(disclosures: duplicated))

    assert_equal 2, boxes.size
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
  end

  test "disclosure box without a matching check defaults to a plain read" do
    boxes = bbox_data(verification(disclosures: [ located("Enjoy responsibly") ]))

    box = boxes.first
    assert_equal "pass", box[:verdict]
    assert_equal "Read", box[:verdict_label]
    assert_equal "Enjoy responsibly", box[:note]
    assert_nil box[:citation]
  end

  test "drops disclosures with malformed boxes" do
    boxes = bbox_data(verification(disclosures: [ located("CONTAINS SULFITES", bbox: [ 1, 2 ]) ]))

    assert_empty boxes
  end
end
