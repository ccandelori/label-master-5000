# frozen_string_literal: true

require "test_helper"

module Rules
  class EngineTest < ActiveSupport::TestCase
    STATUTORY = Rules::Data.statutory_warning_text

    def spirits_application(attrs)
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

    def wine_application(attrs)
      LabelApplication.new({
        serial_number: "26-2001",
        beverage_type: "wine",
        imported: false,
        brand_name: "ABC Wines",
        applicant_name_address: "XYZ Vintners, Napa, CA",
        alcohol_content: 12.5,
        net_contents: "750 mL"
      }.merge(attrs))
    end

    def malt_application(attrs)
      LabelApplication.new({
        serial_number: "26-3001",
        beverage_type: "malt",
        imported: false,
        brand_name: "Stone's Throw",
        applicant_name_address: "Stone's Throw Brewing Co., Seattle, WA",
        alcohol_content: 6.5,
        net_contents: "12 fl oz"
      }.merge(attrs))
    end

    def spirits_facts(overrides)
      Extraction::LabelFacts.from_h({
        "brand_name" => "OLD TOM DISTILLERY",
        "class_type_designation" => "Kentucky Straight Bourbon Whiskey",
        "alcohol_statement" => "45% ALC./VOL. (90 PROOF)",
        "net_contents" => "750 mL",
        "name_address_statement" => "DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO., BARDSTOWN, KY",
        "government_warning_text" => STATUTORY,
        "warning_prefix_bold" => true,
        "disclosures" => []
      }.merge(overrides))
    end

    def wine_facts(overrides)
      Extraction::LabelFacts.from_h({
        "brand_name" => "ABC Wines",
        "class_type_designation" => "Table Wine",
        "alcohol_statement" => "ALC. 12.5% BY VOL.",
        "net_contents" => "750 mL",
        "name_address_statement" => "BOTTLED BY XYZ VINTNERS, NAPA, CA",
        "government_warning_text" => STATUTORY,
        "warning_prefix_bold" => true,
        "disclosures" => [ "CONTAINS SULFITES" ]
      }.merge(overrides))
    end

    def malt_facts(overrides)
      Extraction::LabelFacts.from_h({
        "brand_name" => "STONE'S THROW",
        "class_type_designation" => "India Pale Ale",
        "alcohol_statement" => "6.5% ALC/VOL",
        "net_contents" => "12 fl. oz.",
        "name_address_statement" => "BREWED AND BOTTLED BY STONE'S THROW BREWING CO., SEATTLE, WA",
        "government_warning_text" => STATUTORY,
        "warning_prefix_bold" => true,
        "disclosures" => []
      }.merge(overrides))
    end

    def check(checks, field)
      checks.find { |c| c.field == field }
    end

    test "clean spirits label passes overall" do
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts({}))
      assert_equal "pass", FieldCheck.overall(checks)
      assert_equal "pass", check(checks, "brand_name").verdict
      assert_equal "pass", check(checks, "government_warning_text").verdict
      assert_equal "pass", check(checks, "proof").verdict
      assert_equal "pass", check(checks, "standards_of_fill").verdict
      assert_equal "not_required", check(checks, "country_of_origin").verdict
    end

    test "fuzzy brand match passes with note" do
      checks = Engine.evaluate(
        application: malt_application({}),
        facts: malt_facts({})
      )
      brand = check(checks, "brand_name")
      assert_equal "pass_with_note", brand.verdict
      assert_match(/casing, spacing, or punctuation/, brand.note)
    end

    test "genuinely different brand needs review" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("brand_name" => "YOUNG TOM DISTILLERY")
      )
      assert_equal "needs_review", check(checks, "brand_name").verdict
    end

    test "OCR character noise in a located brand passes via the model's reading" do
      checks = Engine.evaluate(
        application: malt_application(brand_name: "BROUWERIJ 'TIJ"),
        facts: malt_facts(
          "brand_name" => "BROUWERU TIJ",
          "model_texts" => { "brand_name" => "BROUWERIJ 'TIJ" }
        )
      )
      brand = check(checks, "brand_name")
      assert_equal "pass_with_note", brand.verdict
      assert_match(/vision model/, brand.note)
    end

    test "a dropped decimal in located net contents passes via the model's reading" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "15.5 gallons"),
        facts: malt_facts(
          "net_contents" => "15 5 GALLONS",
          "model_texts" => { "net_contents" => "15.5 GALLONS" }
        )
      )
      net = check(checks, "net_contents")
      assert_equal "pass_with_note", net.verdict
      assert_match(/vision model/, net.note)
    end

    test "model_text does not rescue a genuine mismatch" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "brand_name" => "YOUNG TOM DISTILLERY",
          "model_texts" => { "brand_name" => "YOUNG TOM DISTILLERY" }
        )
      )
      assert_equal "needs_review", check(checks, "brand_name").verdict
    end

    test "title-case government warning fails the prefix check only" do
      warning = STATUTORY.sub("GOVERNMENT WARNING:", "Government Warning:")
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => warning))
      assert_equal "pass", check(checks, "government_warning_text").verdict
      assert_equal "fail", check(checks, "government_warning_prefix").verdict
    end

    test "re-worded warning fails the text check" do
      warning = STATUTORY.sub("birth defects", "health issues")
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => warning))
      assert_equal "fail", check(checks, "government_warning_text").verdict
    end

    test "missing warning fails" do
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => nil))
      assert_equal "fail", check(checks, "government_warning_text").verdict
    end

    test "unassessable bold type needs review" do
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("warning_prefix_bold" => nil))
      bold = check(checks, "government_warning_bold")
      assert_equal "needs_review", bold.verdict
    end

    test "proof must equal twice the ABV" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("alcohol_statement" => "45% ALC./VOL. (92 PROOF)")
      )
      assert_equal "fail", check(checks, "proof").verdict
    end

    test "ABV mismatch against the application fails" do
      checks = Engine.evaluate(
        application: spirits_application(alcohol_content: 40.0),
        facts: spirits_facts({})
      )
      assert_equal "fail", check(checks, "alcohol_content").verdict
    end

    test "700 mL spirits bottle gets the discrepancy needs_review" do
      checks = Engine.evaluate(
        application: spirits_application(net_contents: "700 mL"),
        facts: spirits_facts("net_contents" => "700 mL")
      )
      fill = check(checks, "standards_of_fill")
      assert_equal "needs_review", fill.verdict
      assert_match(/27 CFR 5.203/, fill.note)
    end

    test "740 mL wine bottle fails standards of fill" do
      checks = Engine.evaluate(
        application: wine_application(net_contents: "740 mL"),
        facts: wine_facts("net_contents" => "740 mL")
      )
      assert_equal "fail", check(checks, "standards_of_fill").verdict
    end

    test "malt label in metric-only measure fails the system rule" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "355 mL"),
        facts: malt_facts("net_contents" => "355 mL")
      )
      assert_equal "fail", check(checks, "net_contents_measurement_system").verdict
    end

    test "16 fl oz malt statement must read 1 pint" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "16 fl oz"),
        facts: malt_facts("net_contents" => "16 fl oz")
      )
      form = check(checks, "net_contents_form")
      assert_equal "fail", form.verdict
      assert_match(/1 pint/, form.expected)
    end

    test "a parenthesized ounce restatement does not break the 1 pint form" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "1 Pint (16 fl oz)"),
        facts: malt_facts("net_contents" => "1 PINT (16 FL OZ)")
      )
      assert_nil check(checks, "net_contents_form"), "compliant wording emits no form check"
    end

    test "fused OCR wording passes the form rule via the model's reading" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "1 Pint (16 fl oz)"),
        facts: malt_facts(
          "net_contents" => "1PINT 16FLOZ",
          "model_texts" => { "net_contents" => "1 PINT (16 FL OZ)" }
        )
      )
      form = check(checks, "net_contents_form")
      assert_equal "pass_with_note", form.verdict
      assert_match(/vision model/, form.note)
    end

    test "model_text does not rescue genuinely wrong form wording" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "16 fl oz"),
        facts: malt_facts(
          "net_contents" => "16 FL OZ",
          "model_texts" => { "net_contents" => "16 FL OZ" }
        )
      )
      assert_equal "fail", check(checks, "net_contents_form").verdict
    end

    test "missing net contents passes with note when declared embossed" do
      checks = Engine.evaluate(
        application: spirits_application(container_embossed_info: "750 mL blown into the glass"),
        facts: spirits_facts("net_contents" => nil)
      )
      assert_equal "pass_with_note", check(checks, "net_contents").verdict
    end

    test "missing net contents fails without embossed declaration" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("net_contents" => nil)
      )
      assert_equal "fail", check(checks, "net_contents").verdict
    end

    test "color word alone fails for wine designations" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("class_type_designation" => "Rose")
      )
      designation = check(checks, "class_type_designation")
      assert_equal "fail", designation.verdict
      assert_match(/followed by 'Wine'/, designation.note)
    end

    test "designation from the wrong commodity fails" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("class_type_designation" => "India Pale Ale")
      )
      designation = check(checks, "class_type_designation")
      assert_equal "fail", designation.verdict
      assert_match(/malt/, designation.note)
    end

    test "rum below 40 percent fails the minimum bottling proof" do
      checks = Engine.evaluate(
        application: spirits_application(alcohol_content: 35.0),
        facts: spirits_facts(
          "class_type_designation" => "Rum",
          "alcohol_statement" => "35% ALC./VOL."
        )
      )
      assert_equal "fail", check(checks, "designation_minimum_abv").verdict
    end

    test "table wine above 14 percent fails its class constraint" do
      checks = Engine.evaluate(
        application: wine_application(alcohol_content: 15.5),
        facts: wine_facts("alcohol_statement" => "ALC. 15.5% BY VOL.")
      )
      assert_equal "fail", check(checks, "designation_abv_class").verdict
    end

    test "wine tolerance respects the 14 percent boundary" do
      checks = Engine.evaluate(
        application: wine_application(alcohol_content: 13.5, actual_alcohol_content: 14.5),
        facts: wine_facts("alcohol_statement" => "ALC. 13.5% BY VOL.")
      )
      assert_equal "pass", check(checks, "alcohol_content_tolerance").verdict
      assert_equal "fail", check(checks, "alcohol_content_tax_class").verdict
    end

    test "wine within tolerance and same class passes both" do
      checks = Engine.evaluate(
        application: wine_application(alcohol_content: 12.5, actual_alcohol_content: 13.5),
        facts: wine_facts({})
      )
      assert_equal "pass", check(checks, "alcohol_content_tolerance").verdict
      assert_nil check(checks, "alcohol_content_tax_class")
    end

    test "spirits formula tolerance follows the BAM bottling-loss rule with discrepancy band" do
      base = spirits_application(actual_alcohol_content: 44.9)
      checks = Engine.evaluate(application: base, facts: spirits_facts({}))
      assert_equal "pass", check(checks, "alcohol_content_tolerance").verdict

      above = spirits_application(actual_alcohol_content: 45.2)
      checks = Engine.evaluate(application: above, facts: spirits_facts({}))
      tolerance = check(checks, "alcohol_content_tolerance")
      assert_equal "needs_review", tolerance.verdict
      assert_match(/27 CFR 5.65/, tolerance.note)

      far = spirits_application(actual_alcohol_content: 46.0)
      checks = Engine.evaluate(application: far, facts: spirits_facts({}))
      assert_equal "fail", check(checks, "alcohol_content_tolerance").verdict
    end

    test "wine range statement spread limits" do
      checks = Engine.evaluate(
        application: wine_application(alcohol_content: nil),
        facts: wine_facts("alcohol_statement" => "9% TO 12% ALC. BY VOL.")
      )
      assert_equal "pass", check(checks, "alcohol_content_range").verdict

      checks = Engine.evaluate(
        application: wine_application(alcohol_content: nil),
        facts: wine_facts("alcohol_statement" => "8% TO 12% ALC. BY VOL.")
      )
      assert_equal "fail", check(checks, "alcohol_content_range").verdict
    end

    test "malt alcohol statement is optional" do
      checks = Engine.evaluate(
        application: malt_application(alcohol_content: nil),
        facts: malt_facts("alcohol_statement" => nil)
      )
      assert_equal "not_required", check(checks, "alcohol_content").verdict
    end

    test "spirits without an alcohol statement fail" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("alcohol_statement" => nil)
      )
      assert_equal "fail", check(checks, "alcohol_content").verdict
    end

    test "blended whisky requires a commodity statement" do
      facts = spirits_facts(
        "class_type_designation" => "Blended Whiskey",
        "alcohol_statement" => "40% ALC./VOL.",
        "commodity_statement" => nil
      )
      checks = Engine.evaluate(application: spirits_application(alcohol_content: 40.0), facts: facts)
      assert_equal "fail", check(checks, "commodity_statement").verdict
    end

    test "valid commodity statement passes" do
      facts = spirits_facts(
        "class_type_designation" => "Blended Whiskey",
        "alcohol_statement" => "40% ALC./VOL.",
        "commodity_statement" => "70% NEUTRAL SPIRITS DISTILLED FROM GRAIN"
      )
      checks = Engine.evaluate(application: spirits_application(alcohol_content: 40.0), facts: facts)
      assert_equal "pass", check(checks, "commodity_statement").verdict
    end

    test "domestic Munich beer without qualifier fails" do
      checks = Engine.evaluate(
        application: malt_application({}),
        facts: malt_facts("class_type_designation" => "Munich")
      )
      assert_equal "fail", check(checks, "designation_origin_qualifier").verdict
    end

    test "domestic Munich type beer passes the qualifier rule" do
      checks = Engine.evaluate(
        application: malt_application({}),
        facts: malt_facts("class_type_designation" => "Munich Type")
      )
      assert_nil check(checks, "designation_origin_qualifier")
    end

    test "wine vintage without appellation fails" do
      checks = Engine.evaluate(
        application: wine_application(vintage_year: 2024),
        facts: wine_facts("vintage_year" => 2024, "appellation" => nil)
      )
      assert_equal "fail", check(checks, "vintage_appellation").verdict
    end

    test "wine vintage with appellation passes the presence rule" do
      checks = Engine.evaluate(
        application: wine_application(vintage_year: 2024, appellation: "Napa Valley"),
        facts: wine_facts("vintage_year" => 2024, "appellation" => "Napa Valley")
      )
      assert_nil check(checks, "vintage_appellation")
      assert_equal "pass", check(checks, "vintage_date").verdict
      assert_equal "pass", check(checks, "appellation").verdict
    end

    test "label varietal missing from the application fails" do
      checks = Engine.evaluate(
        application: wine_application(varietals: [ "Merlot" ], appellation: "California"),
        facts: wine_facts("varietals" => [ "Merlot", "Syrah" ], "appellation" => "California")
      )
      varietals = check(checks, "varietals")
      assert_equal "fail", varietals.verdict
      assert_match(/Syrah/, varietals.note)
    end

    test "missing wine sulfite statement needs review" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("disclosures" => [])
      )
      sulfites = check(checks, "disclosure_sulfites")
      assert_equal "needs_review", sulfites.verdict
    end

    test "formula sulfite flag makes the missing disclosure a failure" do
      checks = Engine.evaluate(
        application: wine_application(contains_sulfites_10ppm: true),
        facts: wine_facts("disclosures" => [])
      )
      assert_equal "fail", check(checks, "disclosure_sulfites").verdict
    end

    test "malt sulfites without formula data are not required" do
      checks = Engine.evaluate(application: malt_application({}), facts: malt_facts({}))
      assert_equal "not_required", check(checks, "disclosure_sulfites").verdict
    end

    test "lowercase aspartame disclosure fails the caps requirement" do
      checks = Engine.evaluate(
        application: malt_application(contains_aspartame: true),
        facts: malt_facts("disclosures" => [ "Phenylketonurics: Contains Phenylalanine." ])
      )
      aspartame = check(checks, "disclosure_aspartame")
      assert_equal "fail", aspartame.verdict
      assert_match(/capital letters/, aspartame.note)
    end

    test "imported product needs a matching country of origin statement" do
      app = spirits_application(imported: true, country_of_origin: "Scotland")
      checks = Engine.evaluate(
        application: app,
        facts: spirits_facts(
          "class_type_designation" => "Scotch Whisky",
          "alcohol_statement" => "43% ALC./VOL.",
          "country_of_origin_statement" => "PRODUCT OF SCOTLAND",
          "name_address_statement" => "IMPORTED BY GLEN IMPORTS, NEW YORK, NY"
        )
      )
      assert_equal "pass", check(checks, "country_of_origin").verdict
    end

    test "imported product without the statement fails" do
      app = spirits_application(imported: true, country_of_origin: "Scotland")
      checks = Engine.evaluate(
        application: app,
        facts: spirits_facts(
          "class_type_designation" => "Scotch Whisky",
          "alcohol_statement" => "43% ALC./VOL.",
          "name_address_statement" => "IMPORTED BY GLEN IMPORTS, NEW YORK, NY"
        )
      )
      assert_equal "fail", check(checks, "country_of_origin").verdict
    end

    test "wine under 7 percent is outside Part 4 but keeps the warning" do
      checks = Engine.evaluate(
        application: wine_application(alcohol_content: 5.5),
        facts: wine_facts("alcohol_statement" => "ALC. 5.5% BY VOL.")
      )
      assert_equal "not_applicable", check(checks, "part_4_coverage").verdict
      assert_nil check(checks, "standards_of_fill")
      assert_equal "pass", check(checks, "government_warning_text").verdict
    end

    test "cocktail without component declaration fails" do
      checks = Engine.evaluate(
        application: spirits_application(alcohol_content: 12.5, net_contents: "1.75 L"),
        facts: spirits_facts(
          "class_type_designation" => "Margarita",
          "alcohol_statement" => "12.5% ALC/VOL",
          "net_contents" => "1.75 L"
        )
      )
      assert_equal "fail", check(checks, "cocktail_declaration").verdict
    end

    test "every check carries a citation" do
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts({}))
      checks.each do |c|
        assert c.citation.present?, "#{c.field} is missing a citation"
      end
    end
  end
end
