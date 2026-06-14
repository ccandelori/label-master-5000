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

    test "passes when compact application address omits commas" do
      result = check(
        { applicant_name_address: "CREDO PROPERTIES LLC 5220 ETON PL Mechanicsburg PA 17055", imported: true },
        "IMPORTED BY CREDO PROPERTIES LLC MECHANICSBURG, PA"
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

    test "passes with note when imported label uses shortened applicant trade name with city and state" do
      result = check(
        {
          imported: true,
          applicant_name_address: "DIAGEO AMERICAS SUPPLY, INC., 3 WORLD TRADE CENTER STE 41-C, New York, NY, 10007"
        },
        "Imported by Diageo, New York, NY"
      )

      assert_equal "pass_with_note", result.verdict
      assert_match(/shortened importer name/, result.note)
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

    test "high-confidence near identity match passes with note as likely character noise" do
      result = Checks::Identity.match_verdict(
        field: "brand_name", expected: "BROUWERIJ TIJ", extracted: "BROUWERU TIJ",
        citation: "BAM", confidence: 0.96
      )

      assert_equal "pass_with_note", result.verdict
      assert_match(/Near match/, result.note)
    end

    test "near identity match without high confidence still needs review" do
      result = Checks::Identity.match_verdict(
        field: "brand_name", expected: "BROUWERIJ TIJ", extracted: "BROUWERU TIJ",
        citation: "BAM", confidence: 0.70
      )

      assert_equal "needs_review", result.verdict
    end

    test "high-confidence semantic mismatch still needs review" do
      result = Checks::Identity.match_verdict(
        field: "brand_name", expected: "OLD TOM", extracted: "YOUNG TOM",
        citation: "BAM", confidence: 0.99
      )

      assert_equal "needs_review", result.verdict
    end
  end
end
