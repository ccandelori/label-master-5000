# frozen_string_literal: true

require "test_helper"

class ReviewerDataQualityControllerTest < ActionDispatch::IntegrationTest
  def create_application(serial:, source_kind:, quarantine_reasons: [])
    application = LabelApplication.create!(
      channel: "submitted",
      source_kind: source_kind,
      serial_number: serial,
      beverage_type: "malt",
      brand_name: "BRAND #{serial}",
      applicant_name_address: "Example Brewing, Portland, OR",
      net_contents: "12 fl oz",
      quarantined_at: quarantine_reasons.any? ? Time.current : nil,
      quarantine_reasons: quarantine_reasons
    )
    application
  end

  test "renders source and quarantine counts" do
    create_application(serial: "REAL-1", source_kind: "manual")
    create_application(
      serial: "EVAL-1",
      source_kind: "registry_eval",
      quarantine_reasons: [ "primary_artwork_filename_indicates_back" ]
    )

    get data_quality_path

    assert_response :success
    assert_match(/Data quality/, response.body)
    assert_match(/Visible in results/, response.body)
    assert_match(/Registry eval/, response.body)
    assert_match(/Primary artwork filename indicates a back label/, response.body)
    assert_select "a[href=?]", label_application_path(LabelApplication.find_by!(serial_number: "EVAL-1"))
  end
end
