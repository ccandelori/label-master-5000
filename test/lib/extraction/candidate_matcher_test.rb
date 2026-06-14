# frozen_string_literal: true

require "test_helper"
require "timeout"

class CandidateMatcherTest < ActiveSupport::TestCase
  THRESHOLD = 0.8

  def raw_word(text, x, y, width: 80, height: 20, confidence: 0.9)
    Extraction::OcrClient.build_word(
      text: text,
      x: x,
      y: y,
      width: width,
      height: height,
      confidence: confidence
    )
  end

  def evidence(words)
    raw_page = Extraction::OcrClient::Page.new(number: 1, width: 1200, height: 1000, words: words)
    page = Extraction::OcrEvidenceStore.normalize_page(raw_page)
    Extraction::OcrEvidenceStore::Evidence.new(pages: [ page ], engine_key: "test")
  end

  def find(query, words, threshold: THRESHOLD, limit: 5)
    Extraction::CandidateMatcher.find(query: query, evidence: evidence(words), threshold: threshold, limit: limit)
  end

  test "finds exact values and returns normalized evidence metadata" do
    matches = find("OLD TOM DISTILLERY", [
      raw_word("OLD", 10, 20),
      raw_word("TOM", 100, 20),
      raw_word("DISTILLERY", 190, 20, width: 160)
    ])

    match = matches.first
    assert_equal "OLD TOM DISTILLERY", match.text
    assert_equal "old tom distillery", match.normalized_text
    assert_equal 1.0, match.match_score
    assert_equal 1, match.page
    assert_equal({ x: 10, y: 20, width: 340, height: 20 }, match.bbox.to_h)
    assert_in_delta 0.9, match.confidence
  end

  test "matches through case punctuation and diacritics" do
    matches = find("Cote du Soleil", [
      raw_word("CÔTE", 10, 20),
      raw_word("du", 100, 20),
      raw_word("Soleil!", 160, 20)
    ])

    assert_equal "CÔTE du Soleil!", matches.first.text
    assert_equal "cote du soleil", matches.first.normalized_text
    assert_equal 1.0, matches.first.match_score
  end

  test "repairs hyphenated line breaks before scoring" do
    matches = find("pregnancy", [
      raw_word("preg-", 10, 20),
      raw_word("nancy", 10, 50)
    ])

    assert_equal "pregnancy", matches.first.text
    assert_equal 1.0, matches.first.match_score
  end

  test "finds wrapped statutory warning text across lines" do
    warning = "GOVERNMENT WARNING: (1) According to the Surgeon General, women should not drink"
    words = warning.split.each_with_index.map do |token, index|
      raw_word(token, 20 + (index % 5) * 100, 300 + (index / 5) * 24, width: 90)
    end

    matches = find(warning, words)

    assert_equal warning, matches.first.text
    assert_equal 1.0, matches.first.match_score
    assert matches.first.bbox.height > 20
  end

  test "checks reverse reading order for rotated or sideways OCR output" do
    matches = find("GOVERNMENT WARNING", [
      raw_word("WARNING", 10, 20),
      raw_word("GOVERNMENT", 10, 50, width: 130)
    ])

    assert_equal "GOVERNMENT WARNING", matches.first.text
    assert_equal 1.0, matches.first.match_score
  end

  test "ranks closer candidates before weaker fuzzy matches" do
    words = [
      raw_word("OLD", 10, 20),
      raw_word("TON", 100, 20),
      raw_word("DISTILLERY", 190, 20, width: 160),
      raw_word("OLD", 10, 80),
      raw_word("TOM", 100, 80),
      raw_word("DISTILLERY", 190, 80, width: 160)
    ]

    matches = find("OLD TOM DISTILLERY", words)

    assert_equal "OLD TOM DISTILLERY", matches.first.text
    assert matches.first.match_score > matches.second.match_score
  end

  test "matches a target inside a longer OCR line when the ratio is plausible" do
    matches = find("VODKA SELTZER", [
      raw_word("ULTRA PREMIUM VODKA SELTZER", 10, 20, width: 260)
    ])

    assert_equal "ULTRA PREMIUM VODKA SELTZER", matches.first.text
    assert_equal 0.95, matches.first.match_score
  end

  test "matching five hundred OCR entries stays under the local budget" do
    words = 500.times.map { |index| raw_word("NOISE#{index}", index * 2, index * 2, width: 20) }
    words.concat([
      raw_word("TARGET", 20, 900),
      raw_word("VALUE", 110, 900)
    ])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)

    matches = find("TARGET VALUE", words)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - started
    assert_equal "TARGET VALUE", matches.first.text
    assert_operator elapsed, :<, 100.0
  end

  test "long missing text does not spend seconds in edit distance" do
    query = Rules::Data.statutory_warning_text
    words = 700.times.map do |index|
      raw_word("UNRELATED#{index}", 10 + (index % 20) * 45, 20 + (index / 20) * 18, width: 42, height: 14)
    end

    matches = Timeout.timeout(0.75) { find(query, words, limit: 1) }

    assert_empty matches
  end
end
