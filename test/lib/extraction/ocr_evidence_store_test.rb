# frozen_string_literal: true

require "test_helper"

class OcrEvidenceStoreTest < ActiveSupport::TestCase
  RawWord = Data.define(:text, :x, :y, :width, :height, :confidence)

  class CountingEngine
    attr_reader :calls

    def initialize(pages:)
      @pages = pages
      @calls = 0
    end

    def read(data:, content_type:)
      @calls += 1
      @pages
    end

    def degraded?
      false
    end
  end

  setup do
    OcrReading.delete_all
  end

  def source(checksum)
    Extraction::ArtworkSource.new(data: "image-bytes", content_type: "image/png", checksum: checksum)
  end

  def word(text:, x:, y:, width:, height:, confidence:)
    RawWord.new(text: text, x: x, y: y, width: width, height: height, confidence: confidence)
  end

  def page(words)
    Extraction::OcrClient::Page.new(number: 1, width: 800, height: 1000, words: words)
  end

  test "normalizes OCR pages into queryable words and inferred lines" do
    engine = CountingEngine.new(pages: [
      page([
        word(text: "OLD\nTOM", x: 10, y: 20, width: 80, height: 20, confidence: 96.0),
        word(text: "DISTILLERY", x: 100, y: 22, width: 120, height: 20, confidence: 92.0),
        word(text: "750 mL", x: 10, y: 80, width: 70, height: 20, confidence: 88.0)
      ])
    ])

    evidence = Extraction::OcrEvidenceStore.read(
      artworks: [ source("evidence-normal") ],
      engine: engine,
      engine_key: "test-engine-v1"
    )

    assert_equal "test-engine-v1", evidence.engine_key
    assert_equal [ "OLD TOM", "DISTILLERY", "750 mL" ], evidence.words.map(&:text)
    assert_equal [ "OLD TOM DISTILLERY", "750 mL" ], evidence.lines.map(&:text)
    assert_in_delta 94.0, evidence.lines.first.confidence
    assert_equal "OLD TOM DISTILLERY\n750 mL", evidence.text

    region = Extraction::OcrEvidenceStore::Bbox.new(x: 0, y: 0, width: 240, height: 60)
    assert_equal [ "OLD TOM", "DISTILLERY" ], evidence.words_in_region(page: 1, bbox: region).map(&:text)
    assert_equal [ "OLD TOM DISTILLERY" ], evidence.lines_in_region(page: 1, bbox: region).map(&:text)
  end

  test "replaces invalid bytes and drops malformed word boxes" do
    bad_text = +"MAL"
    bad_text.force_encoding(Encoding::BINARY)
    bad_text << "\xFFBEC".b
    engine = CountingEngine.new(pages: [
      page([
        word(text: bad_text, x: 10, y: 20, width: 80, height: 20, confidence: "70.5"),
        word(text: "NO WIDTH", x: 10, y: 50, width: 0, height: 20, confidence: 80.0),
        word(text: "   ", x: 10, y: 80, width: 80, height: 20, confidence: 80.0)
      ])
    ])

    evidence = Extraction::OcrEvidenceStore.read(
      artworks: [ source("evidence-invalid") ],
      engine: engine,
      engine_key: "test-engine-v1"
    )

    assert_equal [ "MAL?BEC" ], evidence.words.map(&:text)
    assert_in_delta 70.5, evidence.words.first.confidence
  end

  test "empty pages stay queryable" do
    engine = CountingEngine.new(pages: [ page([]) ])

    evidence = Extraction::OcrEvidenceStore.read(
      artworks: [ source("evidence-empty") ],
      engine: engine,
      engine_key: "test-engine-v1"
    )

    assert_empty evidence.words
    assert_empty evidence.lines
    assert_equal "", evidence.text
    assert_nil evidence.page(number: 2)
  end

  test "reads through the existing OCR cache" do
    engine = CountingEngine.new(pages: [
      page([ word(text: "VODKA", x: 10, y: 20, width: 80, height: 20, confidence: 90.0) ])
    ])

    2.times do
      evidence = Extraction::OcrEvidenceStore.read(
        artworks: [ source("evidence-cache") ],
        engine: engine,
        engine_key: "test-engine-v1"
      )
      assert_equal [ "VODKA" ], evidence.words.map(&:text)
      assert_in_delta 90.0, evidence.words.first.confidence
    end

    assert_equal 1, engine.calls
    assert_equal 1, OcrReading.where(blob_checksum: "evidence-cache", engine_key: "test-engine-v1").count
  end
end
