# frozen_string_literal: true

require "test_helper"

class EnrichedOcrTest < ActiveSupport::TestCase
  def magick? = system("which magick > /dev/null 2>&1")

  def word(text, x, y, w, h)
    Extraction::OcrClient::Word.new(text: text, x: x, y: y, width: w, height: h)
  end

  def confident_word(text, x, y, w, h, confidence)
    Extraction::OcrClient.build_word(text: text, x: x, y: y, width: w, height: h, confidence: confidence)
  end

  def page(words, width:, height:)
    [ Extraction::OcrClient::Page.new(number: 1, width: width, height: height, words: words) ]
  end

  # Returns a different word per call so the merged pool's provenance is
  # visible: base, then upscaled, then inverted.
  class SequenceEngine
    attr_reader :calls

    def initialize(responses:)
      @responses = responses
      @calls = []
    end

    def read(data:, content_type:)
      @calls << content_type
      @responses[[ @calls.size - 1, @responses.size - 1 ].min]
    end
  end

  test "merges variant words scaled back to the base pixel basis" do
    skip "imagemagick not available" unless magick?

    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    engine = SequenceEngine.new(responses: [
      page([ word("BASE", 10, 10, 20, 10) ], width: 800, height: 1000),
      page([ confident_word("UPSCALED", 100, 100, 50, 20, 87.0) ], width: 1600, height: 2000),
      page([ word("INVERTED", 5, 6, 7, 8) ], width: 800, height: 1000)
    ])

    pages = Extraction::EnrichedOcr.new(engine: engine).read(data: data, content_type: "image/png")

    assert_equal 3, engine.calls.size
    merged = pages.first
    assert_equal 800, merged.width
    assert_equal %w[BASE UPSCALED INVERTED], merged.words.map(&:text)

    upscaled = merged.words[1]
    assert_equal [ 50, 50, 25, 10 ], [ upscaled.x, upscaled.y, upscaled.width, upscaled.height ],
                 "upscaled-pass geometry maps back to the original basis"
    assert_equal 87.0, upscaled.confidence
    assert_equal [ 5, 6, 7, 8 ], [ merged.words[2].x, merged.words[2].y, merged.words[2].width, merged.words[2].height ]
  end

  test "pdfs get the base pass only" do
    engine = SequenceEngine.new(responses: [ page([ word("PDF", 1, 2, 3, 4) ], width: 100, height: 100) ])
    pages = Extraction::EnrichedOcr.new(engine: engine).read(data: "%PDF-...", content_type: "application/pdf")

    assert_equal 1, engine.calls.size
    assert_equal %w[PDF], pages.first.words.map(&:text)
  end

  test "a failing variant is skipped, the base pass survives" do
    skip "imagemagick not available" unless magick?

    data = File.binread(Rails.root.join("test/fixtures/files/ocr_label.png"))
    engine = Class.new do
      def initialize = @calls = 0
      attr_reader :calls

      def read(data:, content_type:)
        @calls += 1
        raise Extraction::OcrError, "variant choked" if @calls > 1

        [ Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000,
                                          words: [ Extraction::OcrClient::Word.new(text: "BASE", x: 1, y: 2, width: 3, height: 4) ]) ]
      end
    end.new

    pages = Extraction::EnrichedOcr.new(engine: engine).read(data: data, content_type: "image/png")
    assert_equal %w[BASE], pages.first.words.map(&:text)
  end
end
