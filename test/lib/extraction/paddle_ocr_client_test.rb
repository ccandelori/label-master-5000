# frozen_string_literal: true

require "test_helper"

class PaddleOcrClientTest < ActiveSupport::TestCase
  test "parse_page maps the sidecar response to a Page of Words" do
    payload = {
      "width" => 1566,
      "height" => 823,
      "words" => [
        { "text" => "BOURBON", "x" => 619, "y" => 467, "width" => 319, "height" => 79 },
        { "text" => "  ", "x" => 0, "y" => 0, "width" => 1, "height" => 1 },
        { "text" => "WHISKEY", "x" => 640, "y" => 550, "width" => 280, "height" => 60 }
      ]
    }
    page = Extraction::PaddleOcrClient.parse_page(payload, page_number: 2)

    assert_equal 2, page.number
    assert_equal 1566, page.width
    assert_equal 823, page.height
    assert_equal %w[BOURBON WHISKEY], page.words.map(&:text), "blank entries are dropped"
    first = page.words.first
    assert_equal [ 619, 467, 319, 79 ], [ first.x, first.y, first.width, first.height ]
  end

  test "parse_page raises when dimensions are missing" do
    assert_raises(Extraction::OcrError) do
      Extraction::PaddleOcrClient.parse_page({ "words" => [] }, page_number: 1)
    end
  end

  test "read raises OcrError when the sidecar is unreachable" do
    client = Extraction::PaddleOcrClient.new(
      base_url: "http://127.0.0.1:1", pdftoppm: "pdftoppm", dpi: 200, timeout_seconds: 1,
      attempts: 1, backoff_seconds: 0
    )

    error = assert_raises(Extraction::OcrError) do
      client.read(data: "bytes", content_type: "image/png")
    end
    assert_match(/unreachable/, error.message)
  end

  test "read retries connection failures before raising the last error" do
    client = Extraction::PaddleOcrClient.new(
      base_url: "http://127.0.0.1:1", pdftoppm: "pdftoppm", dpi: 200, timeout_seconds: 1,
      attempts: 3, backoff_seconds: 0
    )
    attempts = 0
    client.define_singleton_method(:post_read) do |_data|
      attempts += 1
      raise Extraction::OcrConnectionError, "ocr sidecar unreachable: connection refused"
    end

    assert_raises(Extraction::OcrConnectionError) do
      client.read(data: "bytes", content_type: "image/png")
    end
    assert_equal 3, attempts
  end

  test "read does not retry a failure that is not connection-shaped" do
    client = Extraction::PaddleOcrClient.new(
      base_url: "http://127.0.0.1:1", pdftoppm: "pdftoppm", dpi: 200, timeout_seconds: 1,
      attempts: 3, backoff_seconds: 0
    )
    attempts = 0
    client.define_singleton_method(:post_read) do |_data|
      attempts += 1
      raise Extraction::OcrError, "ocr sidecar read failed: Net::ReadTimeout"
    end

    assert_raises(Extraction::OcrError) do
      client.read(data: "bytes", content_type: "image/png")
    end
    assert_equal 1, attempts, "a slow inference must not be re-submitted"
  end

  test "read returns word boxes from a running sidecar" do
    base_url = ENV.fetch("EXTRACTION_PADDLE_URL", "http://127.0.0.1:8765")
    begin
      Net::HTTP.get_response(URI("#{base_url}/healthz"))
    rescue SystemCallError, IOError
      skip "PaddleOCR sidecar is not running"
    end

    client = Extraction::PaddleOcrClient.new(
      base_url: base_url, pdftoppm: "pdftoppm", dpi: 200, timeout_seconds: 120,
      attempts: 3, backoff_seconds: 4
    )
    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    pages = client.read(data: data, content_type: "image/png")

    assert_equal 1, pages.size
    texts = pages.first.words.map(&:text).join(" ")
    assert_match(/DISTILLERY/i, texts)
  end
end
