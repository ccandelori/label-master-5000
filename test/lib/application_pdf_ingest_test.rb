# frozen_string_literal: true

require "test_helper"

class ApplicationPdfIngestTest < ActiveSupport::TestCase
  SAMPLE_DIR = Rails.root.join("downloads/ttb_cola_approved_applications_2026-06-13")
  HUGO_PDF = SAMPLE_DIR.join("26098001000597__HUGO_S_COCKTAILS.pdf")

  test "parses application fields and renders label artwork from a COLA PDF" do
    source = ApplicationPdfIngest::Source.from_path(HUGO_PDF)
    result = ApplicationPdfIngest.parse(
      sources: [ source ],
      manifest_text: SAMPLE_DIR.join("manifest.json").read
    )

    assert_predicate result, :valid?, result.errors.map(&:message).join("\n")
    assert_equal 1, result.rows.size

    row = result.rows.first
    assert_equal 1, row.row_number
    assert_equal "260371", row.attributes[:serial_number]
    assert_equal "spirits", row.attributes[:beverage_type]
    assert_equal "HUGO'S COCKTAILS", row.attributes[:brand_name]
    assert_equal "MEYER LEMON DROP MARTINI", row.attributes[:fanciful_name]
    assert_equal "VODKA MARTINI (UNDER 48 PROOF)", row.attributes[:declared_class_type]
    assert_match(/Drayhorse Canning and Bottling/, row.attributes[:applicant_name_address])
    assert_equal ColaSampleIngest::NET_CONTENTS_SENTINEL, row.attributes[:net_contents]

    assert_equal "26098001000597__HUGO_S_COCKTAILS.pdf", row.application_pdf.filename
    assert row.application_pdf.data.start_with?("%PDF")
    assert_equal 1, row.artworks.size
    assert_equal "26098001000597__HUGO_S_COCKTAILS-label-1.png", row.artworks.first.filename
    assert_equal "image/png", row.artworks.first.content_type
    assert_operator row.artworks.first.data.bytesize, :>, 10_000
  end

  test "reads serial numbers from the serial column rather than adjacent applicant text" do
    result = ApplicationPdfIngest.parse(
      sources: SAMPLE_DIR.glob("*.pdf").sort.map { |path| ApplicationPdfIngest::Source.from_path(path) },
      manifest_text: SAMPLE_DIR.join("manifest.json").read
    )

    assert_predicate result, :valid?, result.errors.map(&:message).join("\n")

    serials_by_pdf = result.rows.index_by { |row| row.application_pdf.filename }.transform_values do |row|
      row.attributes[:serial_number]
    end

    assert_equal "267123", serials_by_pdf.fetch("26106001000008__KUROMATSU-HAKUSHIKA.pdf")
    assert_equal "260033", serials_by_pdf.fetch("26107001000247__BURNETT_S.pdf")
    assert_equal "26PAL1", serials_by_pdf.fetch("26155001000950__TWELVE_OAKS_VINEYARD.pdf")
    refute_includes serials_by_pdf.values, "SAN"
    refute_includes serials_by_pdf.values, "BARDSTOWN"
    refute_includes serials_by_pdf.values, "CARLYLE"
  end

  test "reports non-pdf uploads clearly" do
    source = ApplicationPdfIngest::Source.new(
      path: HUGO_PDF,
      filename: "not-a-pdf.txt",
      content_type: "text/plain"
    )

    result = ApplicationPdfIngest.parse(sources: [ source ], manifest_text: nil)

    assert_not_predicate result, :valid?
    assert_equal :invalid_pdf, result.errors.first.kind
    assert_match(/must be a PDF/, result.errors.first.message)
  end
end
