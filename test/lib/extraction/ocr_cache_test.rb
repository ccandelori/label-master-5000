# frozen_string_literal: true

require "test_helper"

class OcrCacheTest < ActiveSupport::TestCase
  class HealthyEngine
    def degraded? = false
  end

  class DegradedEngine
    def degraded? = true
  end

  def pages
    [ Extraction::OcrClient::Page.new(
      number: 1, width: 800, height: 600,
      words: [ Extraction::OcrClient::Word.new(text: "VODKA", x: 10, y: 20, width: 100, height: 30) ]
    ) ]
  end

  test "first read runs the block and persists; second read skips the block" do
    runs = 0
    2.times do
      result = Extraction::OcrCache.read_through(
        checksum: "abc123", engine_key: "paddle-enriched-v1", engine: HealthyEngine.new
      ) do
        runs += 1
        pages
      end
      page = result.first
      assert_equal 1, page.number
      assert_equal [ 800, 600 ], [ page.width, page.height ]
      word = page.words.first
      assert_equal [ "VODKA", 10, 20, 100, 30 ], [ word.text, word.x, word.y, word.width, word.height ]
    end

    assert_equal 1, runs
    assert_equal 1, OcrReading.where(blob_checksum: "abc123").count
  end

  test "a degraded read is returned but never persisted" do
    result = Extraction::OcrCache.read_through(
      checksum: "abc123", engine_key: "paddle-enriched-v1", engine: DegradedEngine.new
    ) { pages }

    assert_equal "VODKA", result.first.words.first.text
    assert_equal 0, OcrReading.count
  end

  test "disabled cache runs the block without reading or writing rows" do
    Extraction::OcrCache.read_through(
      checksum: "abc123", engine_key: "paddle-enriched-v1", engine: HealthyEngine.new
    ) { pages }
    runs = 0
    original = Extraction::OcrCache.enabled?
    Extraction::OcrCache.enabled = false

    result = Extraction::OcrCache.read_through(
      checksum: "abc123", engine_key: "paddle-enriched-v1", engine: HealthyEngine.new
    ) do
      runs += 1
      pages
    end

    assert_equal "VODKA", result.first.words.first.text
    assert_equal 1, runs
    assert_equal 1, OcrReading.count
  ensure
    Extraction::OcrCache.enabled = original
  end

  test "different engine keys cache independently" do
    %w[paddle-enriched-v1 tesseract-enriched-v1].each do |key|
      Extraction::OcrCache.read_through(
        checksum: "abc123", engine_key: key, engine: HealthyEngine.new
      ) { pages }
    end

    assert_equal 2, OcrReading.count
  end
end
