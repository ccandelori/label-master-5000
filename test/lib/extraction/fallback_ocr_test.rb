# frozen_string_literal: true

require "test_helper"

class FallbackOcrTest < ActiveSupport::TestCase
  class StubEngine
    attr_reader :calls

    def initialize(result: nil, error: nil)
      @result = result
      @error = error
      @calls = 0
    end

    def read(data:, content_type:)
      @calls += 1
      raise @error if @error

      @result
    end
  end

  PAGES = [ Extraction::OcrClient::Page.new(number: 1, width: 10, height: 10, words: []) ].freeze

  test "returns the primary result without consulting the fallback" do
    primary = StubEngine.new(result: PAGES)
    fallback = StubEngine.new(result: [])
    ocr = Extraction::FallbackOcr.new(primary: primary, fallback: fallback)

    assert_equal PAGES, ocr.read(data: "bytes", content_type: "image/png")
    assert_equal 0, fallback.calls
  end

  test "falls back when the primary raises OcrError" do
    primary = StubEngine.new(error: Extraction::OcrError.new("sidecar unreachable"))
    fallback = StubEngine.new(result: PAGES)
    ocr = Extraction::FallbackOcr.new(primary: primary, fallback: fallback)

    assert_equal PAGES, ocr.read(data: "bytes", content_type: "image/png")
    assert_equal 1, primary.calls
    assert_equal 1, fallback.calls
  end

  test "does not fall back when the primary reports backpressure" do
    error = Extraction::OcrBackpressureError.new("ocr sidecar busy", retry_after_seconds: 0)
    primary = StubEngine.new(error: error)
    fallback = StubEngine.new(result: PAGES)
    ocr = Extraction::FallbackOcr.new(primary: primary, fallback: fallback)

    assert_raises(Extraction::OcrBackpressureError) do
      ocr.read(data: "bytes", content_type: "image/png")
    end
    assert_equal 1, primary.calls
    assert_equal 0, fallback.calls
  end

  test "emits a notification when primary OCR degrades to fallback" do
    primary = StubEngine.new(error: Extraction::OcrError.new("sidecar unreachable"))
    fallback = StubEngine.new(result: PAGES)
    ocr = Extraction::FallbackOcr.new(primary: primary, fallback: fallback)
    events = []
    subscriber = lambda do |name, _started, _finished, _id, payload|
      events << payload.merge(event: name)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "verification.ocr_engine.label_verifier") do
      ocr.read(data: "bytes", content_type: "image/png")
    end

    assert_equal [ "fallback" ], events.map { |event| event[:engine] }
    assert_equal [ "sidecar unreachable" ], events.map { |event| event[:error] }
  end

  test "a fallback failure propagates as OcrError" do
    primary = StubEngine.new(error: Extraction::OcrError.new("sidecar unreachable"))
    fallback = StubEngine.new(error: Extraction::OcrError.new("tesseract is not installed"))
    ocr = Extraction::FallbackOcr.new(primary: primary, fallback: fallback)

    assert_raises(Extraction::OcrError) { ocr.read(data: "bytes", content_type: "image/png") }
  end
end
