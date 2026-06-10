# frozen_string_literal: true

require "test_helper"

module Rules
  class IdentityTest < ActiveSupport::TestCase
    RULES = {
      "name_and_address" => {
        "citation" => "BAM Vol 2 1-4 to 1-6",
        "domestic_phrases" => [ "BOTTLED BY", "DISTILLED BY", "PRODUCED BY", "DISTILLED AND BOTTLED BY" ],
        "import_phrases" => [ "IMPORTED BY" ],
        "operation_phrases" => []
      }
    }.freeze

    def application(attrs)
      LabelApplication.new({
        serial_number: "26-1042",
        beverage_type: "spirits",
        imported: false,
        brand_name: "OLD TOM DISTILLERY",
        applicant_name_address: "Old Tom Distilling Co., Bardstown, KY",
        alcohol_content: 45.0,
        net_contents: "750 mL"
      }.merge(attrs))
    end

    def facts(statement)
      Extraction::LabelFacts.from_h({ "name_address_statement" => statement })
    end

    def check(app_attrs, statement)
      Checks::Identity.name_and_address(application(app_attrs), facts(statement), RULES)
    end

    test "passes when the label has name, city, and state but not the street address" do
      result = check(
        { applicant_name_address: "Proof Artisan Distillers LLC, 123 Main St, Fargo, ND 58102" },
        "PRODUCED BY PROOF ARTISAN DISTILLERS, FARGO, ND"
      )

      assert_equal "pass", result.verdict
    end

    test "passes when the label omits the entity suffix from the application" do
      result = check(
        { applicant_name_address: "Old Tom Distilling Co., Bardstown, KY" },
        "DISTILLED AND BOTTLED BY OLD TOM DISTILLING, BARDSTOWN, KY"
      )

      assert_equal "pass", result.verdict
    end

    test "passes when the label spells the state out in full" do
      result = check(
        { applicant_name_address: "Lone Star Spirits, Houston, TX" },
        "BOTTLED BY LONE STAR SPIRITS, HOUSTON, TEXAS"
      )

      assert_equal "pass", result.verdict
    end

    test "needs review when the name matches but city and state are missing" do
      result = check(
        { applicant_name_address: "Old Tom Distilling Co., Bardstown, KY" },
        "DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO."
      )

      assert_equal "needs_review", result.verdict
      assert_match(/place of business/, result.note)
    end

    test "needs review when the applicant name is not on the label" do
      result = check(
        { applicant_name_address: "Old Tom Distilling Co., Bardstown, KY" },
        "BOTTLED BY SOMEBODY ELSE ENTIRELY, BARDSTOWN, KY"
      )

      assert_equal "needs_review", result.verdict
      assert_match(/applicant name/, result.note)
    end

    test "state abbreviation in the middle of a word does not count" do
      result = check(
        { applicant_name_address: "Fine Spirits, Bismarck, ND" },
        "BOTTLED BY FINE SPIRITS BRANDY HOUSE"
      )

      assert_equal "needs_review", result.verdict
    end

    test "fails when the statement lacks a required phrase for spirits" do
      result = check(
        { applicant_name_address: "Old Tom Distilling Co., Bardstown, KY" },
        "OLD TOM DISTILLING CO., BARDSTOWN, KY"
      )

      assert_equal "fail", result.verdict
      assert_match(/explanatory phrase/, result.note)
    end

    test "falls back to word matching when the application has no parseable place" do
      result = check(
        { applicant_name_address: "Maison du Soleil Negociants" },
        "PRODUCED BY MAISON DU SOLEIL NEGOCIANTS"
      )

      assert_equal "pass", result.verdict
    end
  end
end
