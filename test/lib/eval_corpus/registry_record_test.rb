# frozen_string_literal: true

require "test_helper"

# Fixtures are real public registry pages (TTB ID 23001001000001, an
# approved Paradox Brewery COLA) captured once; parsing never touches the
# network.
class RegistryRecordTest < ActiveSupport::TestCase
  def form_html
    File.read(Rails.root.join("test/fixtures/files/ttb_form_sample.html"))
  end

  def detail_html
    File.read(Rails.root.join("test/fixtures/files/ttb_detail_sample.html"))
  end

  test "parses the printable form into application attributes" do
    parsed = EvalCorpus::RegistryRecord.parse_form(form_html)

    assert_equal "23TRIP", parsed.serial_number
    assert_equal "PARADOX BREWERY", parsed.brand_name
    assert_equal "TIPPLE TRIPEL", parsed.fanciful_name
    assert_equal "malt", parsed.beverage_type
    assert_not parsed.imported
    assert_equal "Paradox Brewery LLC 2781 US ROUTE 9 North Hudson NY 12855", parsed.applicant_name_address
    assert_nil parsed.appellation
    assert_empty parsed.varietals
    assert_equal "BEER", parsed.declared_class_type
  end

  test "pairs label images with their printed role" do
    attachments = EvalCorpus::RegistryRecord.parse_form(form_html).image_attachments

    assert_equal 1, attachments.size
    assert_match(/publicViewAttachment.*TIPPLE_TRIPEL_1\.jpg/, attachments.first.path)
    assert_equal "Brand (front) or keg collar", attachments.first.image_type
  end

  test "parses origin and vintage from the detail view" do
    detail = EvalCorpus::RegistryRecord.parse_detail(detail_html)

    assert_equal "NEW YORK", detail[:origin]
    assert_nil detail[:vintage]
  end

  test "a non-COLA page parses to nil" do
    assert_nil EvalCorpus::RegistryRecord.parse_form("<html><body>An error occurred.</body></html>")
  end
end
