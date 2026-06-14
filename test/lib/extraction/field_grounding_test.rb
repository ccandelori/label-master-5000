# frozen_string_literal: true

require "test_helper"

class FieldGroundingTest < ActiveSupport::TestCase
  test "builds generic application search targets without serial numbers" do
    application = LabelApplication.new(
      serial_number: "26-1042",
      brand_name: "MIA-LOU",
      fanciful_name: "Roter Riesling feinherb",
      declared_class_type: "TABLE WHITE WINE",
      alcohol_content: BigDecimal("13.50"),
      net_contents: "750 mL",
      applicant_name_address: "Credo Properties LLC, Mechanicsburg, PA",
      country_of_origin: "Germany",
      varietals: [ "Riesling" ]
    )

    text = Extraction::FieldGrounding.prompt_text(application: application)

    assert_match(/application_search_targets/, text)
    assert_match(/MIA-LOU/, text)
    assert_match(/Roter Riesling feinherb/, text)
    assert_match(/13\.5% ALC\/VOL/, text)
    assert_match(/750 mL/, text)
    assert_match(/Riesling/, text)
    assert_no_match(/26-1042/, text)
  end

  test "alcohol target tells the model not to accept proof-only values" do
    application = LabelApplication.new(alcohol_content: 40.0)
    target = Extraction::FieldGrounding.targets_for(application: application)
                                         .find { |entry| entry.schema_path == "fields.alcohol_statement" }

    assert_includes target.search_values, "40% ALC/VOL"
    assert_match(/proof-only/, target.instruction)
    assert_empty target.search_values.grep(/80\s*proof/i)
  end

  test "nil application keeps the original ungrounded extraction instruction" do
    assert_equal(
      "Extract the label contents as schema-conforming JSON.",
      Extraction::FieldGrounding.prompt_text(application: nil)
    )
  end
end
