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

    test "ambiguous missing brand needs review instead of hard failing" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "brand_name" => nil,
          "field_sources" => { "brand_name" => "vlm_unsupported" }
        )
      )
      brand = check(checks, "brand_name")
      assert_equal "needs_review", brand.verdict
      assert_match(/ambiguous/, brand.note)
    end

    test "missing brand needs review instead of hard failing" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("brand_name" => nil)
      )
      brand = check(checks, "brand_name")

      assert_equal "needs_review", brand.verdict
      assert_match(/not found/, brand.note)
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

    test "a dropped decimal in located net contents parses as the intended volume" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "15.5 gallons"),
        facts: malt_facts(
          "net_contents" => "15 5 GALLONS",
          "model_texts" => { "net_contents" => "15.5 GALLONS" }
        )
      )
      net = check(checks, "net_contents")
      assert_equal "pass", net.verdict
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

    test "OCR noise in located government warning passes via model text" do
      warning = STATUTORY.sub("GOVERNMENT WARNING:", "OVERNMENT WARNING:")
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "government_warning_text" => warning,
          "model_texts" => { "government_warning" => STATUTORY }
        )
      )

      text = check(checks, "government_warning_text")
      prefix = check(checks, "government_warning_prefix")
      assert_equal "pass_with_note", text.verdict
      assert_match(/vision model/, text.note)
      assert_equal "pass_with_note", prefix.verdict
      assert_match(/vision model/, prefix.note)
    end

    test "single-character OCR noise in government warning passes with note" do
      warning = STATUTORY.sub("GOVERNMENT WARNING:", "OVERNMENT WARNING:")
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => warning))

      assert_equal "pass_with_note", check(checks, "government_warning_text").verdict
      assert_equal "pass_with_note", check(checks, "government_warning_prefix").verdict
    end

    test "re-worded warning fails the text check" do
      warning = STATUTORY.sub("birth defects", "health issues")
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => warning))
      assert_equal "fail", check(checks, "government_warning_text").verdict
    end

    test "model-only government warning mismatch needs review instead of hard failing" do
      warning = "#{STATUTORY.sub('during pregnancy and', '')} (3) Alcohol abuse"
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "government_warning_text" => warning,
          "field_sources" => { "government_warning" => "model" }
        )
      )

      result = check(checks, "government_warning_text")
      assert_equal "needs_review", result.verdict
      assert_match(/not OCR-verified/, result.note)
    end

    test "truncated warning text needs review instead of hard failing" do
      warning = STATUTORY.delete_suffix(" and may cause health problems.")
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => warning))

      result = check(checks, "government_warning_text")
      assert_equal "needs_review", result.verdict
      assert_match(/truncated/, result.note)
    end

    test "missing warning needs review" do
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("government_warning_text" => nil))
      assert_equal "needs_review", check(checks, "government_warning_text").verdict
    end

    test "ambiguous missing warning needs review instead of hard failing" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "government_warning_text" => nil,
          "field_sources" => { "government_warning" => "vlm_region" }
        )
      )
      warning = check(checks, "government_warning_text")
      assert_equal "needs_review", warning.verdict
      assert_match(/ambiguous/, warning.note)
    end

    test "unassessable bold type needs review" do
      checks = Engine.evaluate(application: spirits_application({}), facts: spirits_facts("warning_prefix_bold" => nil))
      bold = check(checks, "government_warning_bold")
      assert_equal "needs_review", bold.verdict
    end

    test "line-wrapped government warning does not need paragraph review" do
      warning = STATUTORY.gsub("According to the Surgeon General,", "According to the Surgeon\nGeneral,")
                         .gsub("Consumption of alcoholic beverages", "Consumption of alcoholic\nbeverages")
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "government_warning_text" => warning,
          "warning_continuous_paragraph" => false
        )
      )

      assert_equal "pass", check(checks, "government_warning_text").verdict
      assert_nil check(checks, "government_warning_paragraph")
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

    test "malt label in metric-only measure needs review" do
      checks = Engine.evaluate(
        application: malt_application(net_contents: "355 mL"),
        facts: malt_facts("net_contents" => "355 mL")
      )
      assert_equal "needs_review", check(checks, "net_contents_measurement_system").verdict
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

    test "missing net contents needs review when the application does not state a comparable value" do
      checks = Engine.evaluate(
        application: spirits_application(net_contents: ColaSampleIngest::NET_CONTENTS_SENTINEL),
        facts: spirits_facts("net_contents" => nil)
      )
      net_contents = check(checks, "net_contents")
      assert_equal "needs_review", net_contents.verdict
      assert_equal Rules::Checks::NetContentsCheck::APPLICATION_VALUE_UNREADABLE_NOTE, net_contents.note
    end

    test "uncomparable net contents with a label read is a note, not an action item" do
      checks = Engine.evaluate(
        application: spirits_application(net_contents: ColaSampleIngest::NET_CONTENTS_SENTINEL),
        facts: spirits_facts("net_contents" => "12FL.OZ.(355")
      )
      net_contents = check(checks, "net_contents")

      assert_equal "pass_with_note", net_contents.verdict
      assert_equal Rules::Checks::NetContentsCheck::APPLICATION_VALUE_UNREADABLE_NOTE, net_contents.note
      assert_nil check(checks, "net_contents_measurement_system")
      assert_nil check(checks, "standards_of_fill")
    end

    test "ambiguous missing net contents needs review" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "net_contents" => nil,
          "field_sources" => { "net_contents" => "vlm_unsupported" }
        )
      )
      net_contents = check(checks, "net_contents")
      assert_equal "needs_review", net_contents.verdict
      assert_match(/ambiguous/, net_contents.note)
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

    test "missing class type designation needs review" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("class_type_designation" => nil)
      )
      designation = check(checks, "class_type_designation")

      assert_equal "needs_review", designation.verdict
      assert_match(/confirm visually/, designation.note)
    end

    test "designation names do not match inside unrelated words" do
      checks = Engine.evaluate(
        application: wine_application(declared_class_type: "ROSE WINE"),
        facts: wine_facts(
          "class_type_designation" => "GALYOdN IMPORTED BY",
          "alcohol_statement" => "12.5% ALC/VOL"
        )
      )

      assert_nil check(checks, "designation_abv_class")
      assert_nil check(checks, "semi_generic_appellation")
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

    test "malt IPA abbreviation is a recognized type designation" do
      checks = Engine.evaluate(
        application: malt_application({}),
        facts: malt_facts("class_type_designation" => "IPA")
      )

      designation = check(checks, "class_type_designation")
      assert_equal "pass", designation.verdict
    end

    test "wine varietal designation with appellation passes with note" do
      checks = Engine.evaluate(
        application: wine_application(varietals: [ "Cabernet Sauvignon" ], appellation: "North Coast"),
        facts: wine_facts(
          "class_type_designation" => "CABERNET SAUVIGNON",
          "varietals" => [ "Cabernet Sauvignon" ],
          "appellation" => "North Coast"
        )
      )

      designation = check(checks, "class_type_designation")
      assert_equal "pass_with_note", designation.verdict
      assert_match(/varietal designation/, designation.note)
    end

    test "declared table white wine is satisfied by visible white wine designation" do
      checks = Engine.evaluate(
        application: wine_application(declared_class_type: "TABLE WHITE WINE"),
        facts: wine_facts("class_type_designation" => "White Wine")
      )

      assert_equal "pass", check(checks, "class_type_designation").verdict
      assert_nil check(checks, "declared_class_type")
    end

    test "semi-generic designation with matching protected origin does not require a separate appellation" do
      checks = Engine.evaluate(
        application: wine_application(
          declared_class_type: "SPARKLING WINE/CHAMPAGNE",
          imported: true,
          country_of_origin: "France"
        ),
        facts: wine_facts(
          "class_type_designation" => "Champagne",
          "country_of_origin_statement" => "PRODUCT OF FRANCE",
          "appellation" => nil
        )
      )

      assert_nil check(checks, "semi_generic_appellation")
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

    test "base spirit minimum proof with OCR-only ABV needs review when application ABV is blank" do
      checks = Engine.evaluate(
        application: spirits_application(alcohol_content: nil),
        facts: spirits_facts(
          "class_type_designation" => "Whiskey",
          "alcohol_statement" => "2% ALC/VOL"
        )
      )
      minimum = check(checks, "designation_minimum_abv")

      assert_equal "needs_review", minimum.verdict
      assert_match(/application does not state/, minimum.note)
    end

    test "specialty class does not inherit base spirit minimum proof or commodity statement" do
      checks = Engine.evaluate(
        application: spirits_application(alcohol_content: 4.5, declared_class_type: "VODKA SPECIALTIES"),
        facts: spirits_facts(
          "class_type_designation" => "VODKA",
          "alcohol_statement" => "4.5% ALC/VOL"
        )
      )

      assert_nil check(checks, "designation_minimum_abv")
      assert_nil check(checks, "commodity_statement")
    end

    test "vodka seltzer does not inherit straight vodka minimum proof" do
      checks = Engine.evaluate(
        application: spirits_application(
          alcohol_content: 4.5,
          declared_class_type: "ULTRA-PREMIUM VODKA SELTZER",
          net_contents: "355 mL"
        ),
        facts: spirits_facts(
          "class_type_designation" => "ULTRA-PREMIUM VODKA SELTZER",
          "alcohol_statement" => "4.5% ALC/VOL",
          "net_contents" => "12 FL OZ (355 ML)"
        )
      )

      assert_nil check(checks, "designation_minimum_abv")
    end

    test "cocktail made with a base spirit does not inherit the base spirit minimum proof" do
      checks = Engine.evaluate(
        application: spirits_application(alcohol_content: 10.0, net_contents: "200 mL"),
        facts: spirits_facts(
          "class_type_designation" => "Margarita made with Tequila Blanco and Triple Sec Liqueur",
          "alcohol_statement" => "10% ALC/VOL",
          "net_contents" => "200 mL"
        )
      )

      assert_nil check(checks, "designation_minimum_abv")
      assert_nil check(checks, "cocktail_declaration")
    end

    test "composite fanciful name can be satisfied across visible identity fields" do
      checks = Engine.evaluate(
        application: spirits_application(
          brand_name: "LATE CHECKOUT",
          fanciful_name: "LATE CHECKOUT VODKA SELTZER RASPBERRY",
          declared_class_type: "VODKA SELTZER"
        ),
        facts: spirits_facts(
          "brand_name" => "LATE CHECKOUT",
          "class_type_designation" => "ULTRA-PREMIUM VODKA SELTZER",
          "fanciful_name" => "RASPBERRY"
        )
      )

      fanciful = check(checks, "fanciful_name")
      assert_equal "pass_with_note", fanciful.verdict
      assert_match(/visible identity fields/, fanciful.note)
    end

    test "metric supplement satisfies spirits net contents measurement system" do
      checks = Engine.evaluate(
        application: spirits_application(net_contents: "355 mL"),
        facts: spirits_facts("net_contents" => "12 FL OZ (355 ML)")
      )

      assert_equal "pass", check(checks, "net_contents").verdict
      assert_nil check(checks, "net_contents_measurement_system")
    end

    test "recognized designation read into the fanciful slot passes with note" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "class_type_designation" => nil,
          "fanciful_name" => "VODKA"
        )
      )

      designation = check(checks, "class_type_designation")
      assert_equal "pass_with_note", designation.verdict
      assert_match(/fanciful-name slot/, designation.note)
    end

    test "ambiguous missing class type designation needs review" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "class_type_designation" => nil,
          "field_sources" => { "class_type_designation" => "vlm_unsupported" }
        )
      )

      designation = check(checks, "class_type_designation")
      assert_equal "needs_review", designation.verdict
      assert_match(/ambiguous/, designation.note)
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

    test "missing name and address needs review instead of auto failure" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("name_address_statement" => nil)
      )
      name_address = check(checks, "name_and_address")

      assert_equal "needs_review", name_address.verdict
      assert_match(/not found/, name_address.note)
    end

    test "spirits without an alcohol statement fail" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts("alcohol_statement" => nil)
      )
      assert_equal "fail", check(checks, "alcohol_content").verdict
    end

    test "ambiguous missing spirits alcohol statement needs review" do
      checks = Engine.evaluate(
        application: spirits_application({}),
        facts: spirits_facts(
          "alcohol_statement" => nil,
          "field_sources" => { "alcohol_statement" => "vlm_region" }
        )
      )
      alcohol = check(checks, "alcohol_content")
      assert_equal "needs_review", alcohol.verdict
      assert_match(/ambiguous/, alcohol.note)
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

    test "wine placement is not checked for a single-label product" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("field_pages" => { "brand_name" => 1, "net_contents" => 1 })
      )
      assert_nil check(checks, "brand_label_placement")
    end

    test "wine placement passes when the brand label carries the mandatory trio" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("field_pages" => {
          "brand_name" => 1, "class_type_designation" => 1,
          "alcohol_statement" => 1, "government_warning" => 2
        })
      )
      assert_equal "pass", check(checks, "brand_label_placement").verdict
    end

    test "wine brand name on the back label needs review" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("field_pages" => {
          "brand_name" => 2, "class_type_designation" => 1, "alcohol_statement" => 1
        })
      )
      placement = check(checks, "brand_label_placement")
      assert_equal "needs_review", placement.verdict
      assert_equal "27 CFR 4.32(a)", placement.citation
      assert_match(/brand name/, placement.note)
      assert_no_match(/designation/, placement.note)
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

    test "qualified varietal wording matches the declared varietal with note" do
      checks = Engine.evaluate(
        application: wine_application(varietals: [ "Riesling" ], appellation: "Rheingau"),
        facts: wine_facts("varietals" => [ "Roter Riesling" ], "appellation" => "Rheingau")
      )

      varietals = check(checks, "varietals")
      assert_equal "pass_with_note", varietals.verdict
      assert_match(/additional modifier/, varietals.note)
    end

    test "missing wine sulfite statement needs review" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("disclosures" => [])
      )
      sulfites = check(checks, "disclosure_sulfites")
      assert_equal "needs_review", sulfites.verdict
    end

    test "valid disclosure candidate wins over earlier malformed candidate" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("disclosures" => [ "Enthält Sulfite", "contains sulfites" ])
      )

      sulfites = check(checks, "disclosure_sulfites")
      assert_equal "pass", sulfites.verdict
      assert_equal "contains sulfites", sulfites.extracted
    end

    test "malformed disclosure without formula trigger needs review" do
      checks = Engine.evaluate(
        application: wine_application({}),
        facts: wine_facts("disclosures" => [ "sulfite notice" ])
      )
      sulfites = check(checks, "disclosure_sulfites")

      assert_equal "needs_review", sulfites.verdict
      assert_match(/not in a permitted form/, sulfites.note)
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

    test "imported product without the statement needs review" do
      app = spirits_application(imported: true, country_of_origin: "Scotland")
      checks = Engine.evaluate(
        application: app,
        facts: spirits_facts(
          "class_type_designation" => "Scotch Whisky",
          "alcohol_statement" => "43% ALC./VOL.",
          "name_address_statement" => "IMPORTED BY GLEN IMPORTS, NEW YORK, NY"
        )
      )
      assert_equal "needs_review", check(checks, "country_of_origin").verdict
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
