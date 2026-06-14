# frozen_string_literal: true

require "securerandom"
require "test_helper"

class PerformanceVerificationBenchmarkTest < ActiveSupport::TestCase
  STATUTORY = Rules::Data.statutory_warning_text

  class StubExtractor
    def model_id
      "benchmark-model"
    end

    def extract(artworks:, application:)
      payload = {
        "legible" => true,
        "confidence" => 0.95,
        "fields" => {
          "brand_name" => { "text" => "BENCHMARK BRAND", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "fanciful_name" => nil,
          "class_type_designation" => { "text" => "India Pale Ale", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "alcohol_statement" => { "text" => "6% ALC/VOL", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "net_contents" => { "text" => "12 fl oz", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "name_address_statement" => { "text" => "BREWED BY BENCHMARK BREWING, PORTLAND, OR", "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "country_of_origin_statement" => nil,
          "government_warning" => { "text" => STATUTORY, "bbox" => nil, "page" => 1, "confidence" => 0.9 },
          "commodity_statement" => nil,
          "appellation" => nil,
          "vintage" => nil
        },
        "varietals" => [],
        "disclosures" => [],
        "warning_attributes" => { "prefix_all_caps" => true, "prefix_bold" => true, "continuous_paragraph" => true }
      }
      LabelExtractor::Result.new(
        facts: Extraction::FactsMapper.to_facts(payload),
        raw: payload,
        model_id: model_id,
        latency_ms: 1
      )
    end
  end

  setup do
    @original_extractor_factory = VerifyLabelJob.extractor_factory
    VerifyLabelJob.extractor_factory = ->(_provider, _model) { StubExtractor.new }
  end

  teardown do
    VerifyLabelJob.extractor_factory = @original_extractor_factory
  end

  test "runs real records and writes a timing artifact" do
    batch = Batch.create!(name: "Benchmark batch", total_rows: 1)
    application = LabelApplication.new(
      batch: batch,
      row_number: 1,
      serial_number: "PERF-1",
      beverage_type: "malt",
      brand_name: "BENCHMARK BRAND",
      applicant_name_address: "Benchmark Brewing, Portland, OR",
      alcohol_content: 6.0,
      net_contents: "12 fl oz"
    )
    application.artwork.attach(io: StringIO.new("benchmark-bytes"), filename: "label.png", content_type: "image/png")
    application.save!
    output_dir = Rails.root.join("tmp", "perf-test-#{Process.pid}-#{SecureRandom.hex(4)}")

    result = Performance::VerificationBenchmark.new(
      batch_id: batch.id,
      limit: "1",
      output_dir: output_dir,
      mode: "vlm"
    ).run
    artifact = Pathname(result[:artifact_path])
    persisted = JSON.parse(artifact.read)

    assert artifact.exist?
    assert_equal "vlm", persisted.dig("scope", "mode")
    assert_equal true, persisted.dig("scope", "extraction_reuse_enabled")
    assert_equal 1, persisted.dig("summary", "labels")
    assert_equal 1, persisted.dig("summary", "successes")
    assert_equal batch.id, persisted.dig("scope", "batch_id")
    assert_equal [ application.id ], persisted.dig("scope", "label_application_ids")
    assert persisted.dig("summary", "stages", "vlm_extraction", "count").positive?
    assert persisted.dig("summary", "stages", "vlm_reconciliation", "count").positive?
    assert_equal 1, persisted.dig("summary", "extraction_reuse", "fresh")
  end

  test "cold mode disables extraction reuse without deleting existing rows" do
    batch = Batch.create!(name: "Cold benchmark batch", total_rows: 1)
    application = LabelApplication.new(
      batch: batch,
      row_number: 1,
      serial_number: "PERF-COLD-1",
      beverage_type: "malt",
      brand_name: "BENCHMARK BRAND",
      applicant_name_address: "Benchmark Brewing, Portland, OR",
      alcohol_content: 6.0,
      net_contents: "12 fl oz"
    )
    application.artwork.attach(io: StringIO.new("cold-benchmark-bytes"), filename: "label.png", content_type: "image/png")
    application.save!
    output_dir = Rails.root.join("tmp", "perf-test-#{Process.pid}-#{SecureRandom.hex(4)}")

    Performance::VerificationBenchmark.new(
      batch_id: batch.id,
      limit: "1",
      output_dir: output_dir,
      mode: "cached"
    ).run
    assert_equal 1, application.verifications.count
    result = Performance::VerificationBenchmark.new(
      batch_id: batch.id,
      limit: "1",
      output_dir: output_dir,
      mode: "cold"
    ).run
    persisted = JSON.parse(Pathname(result[:artifact_path]).read)

    assert_equal "cold", persisted.dig("scope", "mode")
    assert_equal false, persisted.dig("scope", "extraction_reuse_enabled")
    assert_equal 2, application.verifications.count
    assert_equal false, persisted.dig("records", 0, "extraction_reused")
    assert_equal 0, persisted.dig("summary", "extraction_reuse", "reused")
    assert_equal 1, persisted.dig("summary", "extraction_reuse", "fresh")
    assert_equal true, persisted.dig("summary", "performance_target", "applies")
    assert_equal 5000, persisted.dig("summary", "performance_target", "cold_label_p50_ms")
    assert_includes [ true, false ], persisted.dig("summary", "performance_target", "p50_met")
    assert_equal true, VerifyLabelJob.extraction_reuse_enabled
  end
end
