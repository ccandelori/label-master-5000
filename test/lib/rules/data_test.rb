# frozen_string_literal: true

require "test_helper"

module Rules
  class DataTest < ActiveSupport::TestCase
    test "the shipped rule data loads and validates" do
      assert_nothing_raised { Data.reload! }
    end

    test "exposes per-commodity rules" do
      assert_equal "malt", Data.for(:malt)["commodity"]
      assert_equal "wine", Data.for("wine")["commodity"]
      assert_equal "spirits", Data.for(:spirits)["commodity"]
    end

    test "rejects unknown commodities" do
      assert_raises(Data::InvalidRuleData) { Data.for(:cider) }
    end

    test "statutory warning text matches 27 CFR 16.21" do
      text = Data.statutory_warning_text
      assert text.start_with?("GOVERNMENT WARNING:")
      assert_includes text, "Surgeon General"
      assert_includes text, "birth defects"
      assert_includes text, "operate machinery"
    end

    test "malt tolerance is plus or minus 0.3 percentage points" do
      assert_in_delta 0.3, Data.for(:malt).dig("alcohol_content", "tolerance_percentage_points"), 0.0001
    end

    test "wine tolerances split at 14 percent" do
      tolerance = Data.for(:wine).dig("alcohol_content", "tolerance_percentage_points")
      assert_in_delta 1.5, tolerance["at_or_under_14"], 0.0001
      assert_in_delta 1.0, tolerance["over_14"], 0.0001
    end

    test "wine standards of fill include 750 but not 700" do
      fills = Data.for(:wine).dig("net_contents", "standards_of_fill_ml")
      assert_includes fills, 750
      assert_not_includes fills, 700
    end

    test "spirits discrepancy records the current-regulation 700 mL size" do
      discrepancy = Data.for(:spirits).dig("net_contents", "discrepancy")
      assert_includes discrepancy["additional_sizes_ml"], 700
      assert_equal "27 CFR 5.203", discrepancy["current_regulation"]
    end

    test "malt requires American measure, wine and spirits require metric" do
      assert_equal "us_customary", Data.for(:malt).dig("net_contents", "required_system")
      assert_equal "metric", Data.for(:wine).dig("net_contents", "required_system")
      assert_equal "metric", Data.for(:spirits).dig("net_contents", "required_system")
    end

    test "every designation entry carries names, kind, and sufficiency" do
      Data::COMMODITIES.each do |commodity|
        Data.for(commodity).dig("designations", "entries").each do |entry|
          assert entry["names"].any?, "#{commodity} entry without names"
          assert entry["kind"].present?
          assert [ true, false, "conditional" ].include?(entry["sufficient"])
        end
      end
    end

    test "wine sulfite policy flags missing statements for review" do
      assert_equal "needs_review", Data.for(:wine).dig("sulfite_policy", "missing_statement_verdict")
    end

    test "aspartame disclosure requires capital letters" do
      aspartame = Data.for(:malt)["disclosures"].find { |d| d["key"] == "aspartame" }
      assert aspartame["all_caps_required"]
      assert_includes aspartame["required_text"].first, "PHENYLKETONURICS"
    end

    test "blended whisky requires a commodity statement" do
      group1 = Data.for(:spirits).dig("commodity_statement", "group_1", "classes")
      assert_includes group1, "Blended Whisky"
    end

    test "validation catches missing citations" do
      broken = Data.load_file("malt")
      broken["alcohol_content"].delete("citation")
      error = assert_raises(Data::InvalidRuleData) { Data.validate_commodity!("malt", broken) }
      assert_match(/alcohol_content.citation/, error.message)
    end

    test "validation catches non-positive standards of fill" do
      broken = Data.load_file("spirits")
      broken["net_contents"]["standards_of_fill_ml"] << -5
      assert_raises(Data::InvalidRuleData) { Data.validate_commodity!("spirits", broken) }
    end

    test "validation catches designation entries with bad sufficiency" do
      broken = Data.load_file("wine")
      broken["designations"]["entries"].first["sufficient"] = "sometimes"
      assert_raises(Data::InvalidRuleData) { Data.validate_commodity!("wine", broken) }
    end

    test "validation catches disclosures without text or pattern" do
      broken = Data.load_file("malt")
      broken["disclosures"].first["required_text"] = []
      assert_raises(Data::InvalidRuleData) { Data.validate_commodity!("malt", broken) }
    end
  end
end
