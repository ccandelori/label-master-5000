# frozen_string_literal: true

require "test_helper"

class OcrClientTest < ActiveSupport::TestCase
  SAMPLE_TSV = <<~TSV
    level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
    1\t1\t0\t0\t0\t0\t0\t0\t800\t1000\t-1\t
    2\t1\t1\t0\t0\t0\t100\t80\t350\t42\t-1\t
    5\t1\t1\t1\t1\t1\t100\t80\t60\t40\t96.5\tOLD
    5\t1\t1\t1\t1\t2\t170\t80\t70\t40\t95.1\tTOM
    5\t1\t1\t1\t1\t3\t250\t80\t200\t42\t91.0\tDISTILLERY
    5\t1\t1\t1\t2\t1\t300\t600\t40\t20\t88.0\t
  TSV

  test "parse_tsv maps word rows and page dimensions" do
    page = Extraction::OcrClient.parse_tsv(SAMPLE_TSV, page_number: 1)

    assert_equal 1, page.number
    assert_equal 800, page.width
    assert_equal 1000, page.height
    assert_equal %w[OLD TOM DISTILLERY], page.words.map(&:text)

    first = page.words.first
    assert_equal [ 100, 80, 60, 40 ], [ first.x, first.y, first.width, first.height ]
  end

  test "parse_tsv raises when no page dimensions are present" do
    assert_raises(Extraction::OcrError) do
      Extraction::OcrClient.parse_tsv("level\tpage_num\n", page_number: 1)
    end
  end

  test "read raises OcrError when the binary is missing" do
    client = Extraction::OcrClient.new(tesseract: "definitely-not-tesseract", pdftoppm: "missing", dpi: 200)

    error = assert_raises(Extraction::OcrError) do
      client.read(data: "bytes", content_type: "image/png")
    end
    assert_match(/not installed/, error.message)
  end

  test "read returns word boxes for a real label image" do
    skip "tesseract binary not available" unless system("which tesseract > /dev/null 2>&1")

    client = Extraction::OcrClient.new(tesseract: "tesseract", pdftoppm: "pdftoppm", dpi: 200)
    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    pages = client.read(data: data, content_type: "image/png")

    assert_equal 1, pages.size
    page = pages.first
    assert_equal 800, page.width
    assert_equal 1000, page.height

    texts = page.words.map(&:text)
    assert_includes texts, "DISTILLERY"
    assert_includes texts, "750"

    brand = page.words.select { |w| %w[OLD TOM DISTILLERY].include?(w.text) }
    assert brand.size >= 3, "expected the brand words to be located"
    assert brand.all? { |w| w.width.positive? && w.height.positive? }
  end
end
