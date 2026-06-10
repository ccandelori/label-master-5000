# frozen_string_literal: true

require "application_system_test_case"

class SingleLabelVerificationTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  STATUTORY = Rules::Data.statutory_warning_text

  def stub_payload
    {
      "legible" => true,
      "confidence" => 0.95,
      "fields" => {
        "brand_name" => { "text" => "OLD TOM DISTILLERY", "bbox" => [ 10, 10, 100, 20 ], "page" => 1, "confidence" => 0.98 },
        "fanciful_name" => nil,
        "class_type_designation" => { "text" => "Kentucky Straight Bourbon Whiskey", "bbox" => [ 10, 40, 100, 10 ], "page" => 1, "confidence" => 0.9 },
        "alcohol_statement" => { "text" => "45% ALC./VOL. (90 PROOF)", "bbox" => [ 10, 60, 80, 10 ], "page" => 1, "confidence" => 0.9 },
        "net_contents" => { "text" => "750 mL", "bbox" => [ 10, 80, 40, 10 ], "page" => 1, "confidence" => 0.9 },
        "name_address_statement" => { "text" => "DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO., BARDSTOWN, KY", "bbox" => [ 10, 100, 200, 10 ], "page" => 1, "confidence" => 0.9 },
        "country_of_origin_statement" => nil,
        "government_warning" => { "text" => STATUTORY.sub("GOVERNMENT WARNING:", "Government Warning:"), "bbox" => [ 10, 120, 220, 30 ], "page" => 1, "confidence" => 0.9 },
        "commodity_statement" => nil,
        "appellation" => nil,
        "vintage" => nil
      },
      "varietals" => [],
      "disclosures" => [],
      "warning_attributes" => { "prefix_all_caps" => false, "prefix_bold" => true, "continuous_paragraph" => true }
    }
  end

  class StubExtractor
    def initialize(payload)
      @payload = payload
    end

    def extract(data:, content_type:)
      LabelExtractor::Result.new(
        facts: Extraction::FactsMapper.to_facts(@payload),
        raw: @payload,
        model_id: "stub-model",
        latency_ms: 1200
      )
    end
  end

  test "agent submits a label, sees cited verdicts, and records a decision" do
    original = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = -> { StubExtractor.new(stub_payload) }

    visit root_path
    fill_in "Serial number", with: "26-1042"
    select "Distilled spirits", from: "Type of product"
    fill_in "Brand name", with: "OLD TOM DISTILLERY"
    fill_in "Applicant name and address (as on the permit)", with: "Old Tom Distilling Co., Bardstown, KY"
    fill_in "Alcohol content (% by volume)", with: "45"
    fill_in "Net contents", with: "750 mL"
    attach_file "Label artwork", Rails.root.join("test/fixtures/files/label.png")

    perform_enqueued_jobs do
      click_on "Check this label"
    end

    # The job ran; reload the page (no JS in rack_test, so no live stream).
    visit current_path

    assert_text "Problems found"
    assert_text "GOVERNMENT WARNING must appear in capital letters"
    assert_text "27 CFR 16.22"
    assert_match(/checked in \d+(\.\d+)?s/, page.text)

    click_on "✗ Reject"
    assert_text "Decision recorded"
    assert_text "Your decision: Reject"
  ensure
    VerifyLabelJob.extractor_factory = original
  end
end
