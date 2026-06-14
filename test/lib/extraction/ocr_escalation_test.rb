# frozen_string_literal: true

require "test_helper"

class OcrEscalationTest < ActiveSupport::TestCase
  class VariantEngine
    attr_reader :calls

    def initialize(responses:)
      @responses = responses
      @calls = []
    end

    def read(data:, content_type:)
      @calls << [ data, content_type ]
      @responses.fetch(data) { empty_page }
    end

    private

    def empty_page
      [ Extraction::OcrClient::Page.new(number: 1, width: 100, height: 100, words: []) ]
    end
  end

  class SlowVariantEngine < VariantEngine
    def initialize(responses:, sleep_seconds:)
      super(responses: responses)
      @sleep_seconds = sleep_seconds
    end

    def read(data:, content_type:)
      sleep(@sleep_seconds)
      super
    end
  end

  def raw_word(text, x, y, width, height, confidence)
    Extraction::OcrClient.build_word(
      text: text,
      x: x,
      y: y,
      width: width,
      height: height,
      confidence: confidence
    )
  end

  def raw_page(words, width, height)
    Extraction::OcrClient::Page.new(number: 1, width: width, height: height, words: words)
  end

  def evidence(words, width, height)
    Extraction::OcrEvidenceStore::Evidence.new(
      pages: [ Extraction::OcrEvidenceStore.normalize_page(raw_page(words, width, height)) ],
      engine_key: "test"
    )
  end

  def artwork(data)
    Extraction::ArtworkSource.new(data: data, content_type: "image/png", checksum: data)
  end

  def field(name, expected_text, bbox_hint, page)
    Extraction::OcrEscalation::ExpectedField.new(
      name: name,
      expected_text: expected_text,
      bbox_hint: bbox_hint,
      page: page
    )
  end

  def deadline
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) + 10_000
  end

  def with_image_variant_stubs(stubs)
    originals = stubs.keys.to_h { |name| [ name, Extraction::ImageVariants.method(name) ] }
    stubs.each do |name, implementation|
      Extraction::ImageVariants.define_singleton_method(name, implementation)
    end
    yield
  ensure
    originals.each do |name, implementation|
      Extraction::ImageVariants.define_singleton_method(name, implementation)
    end
  end

  test "rotation pass merges evidence back into the original page basis" do
    base = evidence([ raw_word("noise", 1, 1, 5, 5, 0.9) ], 200, 100)
    engine = VariantEngine.new(responses: {
      "front:rotate:90" => [ raw_page([ raw_word("GOVERNMENT", 60, 20, 15, 40, 92.0) ], 100, 200) ]
    })

    with_image_variant_stubs(
      rotate: ->(data, degrees:) { "#{data}:rotate:#{degrees}" },
      enhance_contrast: ->(data) { "#{data}:contrast" }
    ) do
      result = Extraction::OcrEscalation.run(
        artworks: [ artwork("front") ],
        evidence: base,
        engine: engine,
        engine_key: "tesseract",
        missing_fields: [ field("government_warning", "GOVERNMENT WARNING", nil, 1) ],
        deadline_ms: deadline,
        min_remaining_ms: 3_000,
        confidence_threshold: 0.6,
        match_threshold: 0.8
      )

      assert_includes result.strategies.map(&:name), "rotate_90"
      rotated = result.evidence.words.find { |word| word.text == "GOVERNMENT" }
      assert_equal 1, rotated.page
      assert_equal [ 20, 25, 40, 15 ], [
        rotated.bbox.x, rotated.bbox.y, rotated.bbox.width, rotated.bbox.height
      ]
      assert_equal 92.0, rotated.confidence
    end
  end

  test "rotation passes run concurrently" do
    base = evidence([ raw_word("noise", 1, 1, 5, 5, 0.9) ], 200, 100)
    engine = SlowVariantEngine.new(
      responses: {
        "front:rotate:90" => [ raw_page([ raw_word("GOVERNMENT", 60, 20, 15, 40, 92.0) ], 100, 200) ],
        "front:rotate:270" => [ raw_page([ raw_word("WARNING", 60, 20, 15, 40, 92.0) ], 100, 200) ]
      },
      sleep_seconds: 0.2
    )

    with_image_variant_stubs(
      rotate: ->(data, degrees:) { "#{data}:rotate:#{degrees}" },
      enhance_contrast: ->(data) { "#{data}:contrast" }
    ) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      result = Extraction::OcrEscalation.run(
        artworks: [ artwork("front") ],
        evidence: base,
        engine: engine,
        engine_key: "tesseract",
        missing_fields: [ field("government_warning", "GOVERNMENT WARNING", nil, 1) ],
        deadline_ms: deadline,
        min_remaining_ms: 3_000,
        confidence_threshold: 0.6,
        match_threshold: 0.8
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - started

      assert_includes result.strategies.map(&:name), "rotate_90"
      assert_includes result.strategies.map(&:name), "rotate_270"
      assert_operator elapsed, :<, 350
    end
  end

  test "crop pass maps upscaled crop words back into page coordinates" do
    base = evidence([ raw_word("BRAND", 5, 5, 20, 10, 0.1) ], 200, 100)
    engine = VariantEngine.new(responses: {
      "front:crop" => [ raw_page([ raw_word("BRAND", 20, 10, 30, 10, 81.0) ], 100, 60) ]
    })

    with_image_variant_stubs(
      enhance_contrast: ->(data) { "#{data}:contrast" },
      crop: ->(data, rect:, upscale_factor:) { "#{data}:crop" }
    ) do
      result = Extraction::OcrEscalation.run(
        artworks: [ artwork("front") ],
        evidence: base,
        engine: engine,
        engine_key: "tesseract",
        missing_fields: [ field("brand_name", "BRAND", [ 10, 20, 50, 30 ], 1) ],
        deadline_ms: deadline,
        min_remaining_ms: 3_000,
        confidence_threshold: 0.6,
        match_threshold: 0.8
      )

      assert_includes result.strategies.map(&:name), "crop"
      cropped = result.evidence.words.select { |word| word.text == "BRAND" }.max_by(&:confidence)
      assert_equal [ 20, 25, 15, 5 ], [
        cropped.bbox.x, cropped.bbox.y, cropped.bbox.width, cropped.bbox.height
      ]
      assert_equal 81.0, cropped.confidence
    end
  end

  test "does not run escalation without missing fields or time budget" do
    base = evidence([ raw_word("noise", 1, 1, 5, 5, 0.1) ], 200, 100)
    engine = VariantEngine.new(responses: {})

    no_fields = Extraction::OcrEscalation.run(
      artworks: [ artwork("front") ],
      evidence: base,
      engine: engine,
      engine_key: "tesseract",
      missing_fields: [],
      deadline_ms: deadline,
      min_remaining_ms: 3_000,
      confidence_threshold: 0.6,
      match_threshold: 0.8
    )
    no_budget = Extraction::OcrEscalation.run(
      artworks: [ artwork("front") ],
      evidence: base,
      engine: engine,
      engine_key: "tesseract",
      missing_fields: [ field("brand_name", "BRAND", nil, 1) ],
      deadline_ms: Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond),
      min_remaining_ms: 3_000,
      confidence_threshold: 0.6,
      match_threshold: 0.8
    )

    assert_empty no_fields.strategies
    assert_empty no_budget.strategies
    assert_empty engine.calls
  end

  test "strong base evidence is not escalated" do
    base = evidence([ raw_word("BRAND", 1, 1, 20, 10, 95.0), raw_word("NAME", 30, 1, 20, 10, 94.0),
                      raw_word("NET", 1, 20, 20, 10, 92.0), raw_word("CONTENTS", 30, 20, 20, 10, 92.0),
                      raw_word("WARNING", 1, 40, 20, 10, 90.0), raw_word("TEXT", 30, 40, 20, 10, 90.0),
                      raw_word("ADDRESS", 1, 60, 20, 10, 88.0), raw_word("HERE", 30, 60, 20, 10, 88.0) ], 200, 100)
    engine = VariantEngine.new(responses: {})

    result = Extraction::OcrEscalation.run(
      artworks: [ artwork("front") ],
      evidence: base,
      engine: engine,
      engine_key: "tesseract",
      missing_fields: [ field("brand_name", "UNKNOWN", nil, 1) ],
      deadline_ms: deadline,
      min_remaining_ms: 3_000,
      confidence_threshold: 0.6,
      match_threshold: 0.8
    )

    assert_empty result.strategies
    assert_empty engine.calls
  end
end
