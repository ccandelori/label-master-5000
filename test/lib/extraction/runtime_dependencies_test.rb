# frozen_string_literal: true

require "test_helper"

class RuntimeDependenciesTest < ActiveSupport::TestCase
  Config = Data.define(:ocr_engine, :paddle_url, :ocr_auto_start, :ocr_start_timeout_seconds)

  class FakeCommandChecker
    def initialize(available)
      @available = available
    end

    def available?(command)
      @available.include?(command)
    end
  end

  class FakeHttpChecker
    attr_reader :checked

    def initialize(results:, json_results:)
      @results = results
      @json_results = json_results
      @checked = []
    end

    def ok?(url, path)
      @checked << [ url, path ]
      @results.fetch(path)
    end

    def json(url, path)
      @checked << [ url, path ]
      @json_results.fetch(path)
    end
  end

  class FakeSupervisor
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = 0
    end

    def ensure_running
      @calls += 1
      @result
    end
  end

  test "reports missing required commands and paddle sidecar" do
    checker = FakeHttpChecker.new(
      results: { "/healthz" => true, "/readyz" => false },
      json_results: { "/metrics" => nil }
    )
    report = Extraction::RuntimeDependencies.new(
      config: config("paddle"),
      command_checker: FakeCommandChecker.new(%w[magick]),
      http_checker: checker,
      ocr_supervisor: FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "disabled"))
    ).report

    assert_not report[:ok]
    dependencies = report[:dependencies].index_by { |dep| dep[:key] }
    assert dependencies.fetch("magick")[:available]
    assert_not dependencies.fetch("pdftoppm")[:available]
    assert_not dependencies.fetch("tesseract")[:available]
    assert_not dependencies.fetch("paddle_sidecar")[:available]
    assert_equal [
      [ "http://127.0.0.1:8765", "/healthz" ],
      [ "http://127.0.0.1:8765", "/readyz" ]
    ], checker.checked
  end

  test "reports paddle capacity and busy counters when sidecar is ready" do
    checker = FakeHttpChecker.new(
      results: { "/healthz" => true, "/readyz" => true },
      json_results: {
        "/metrics" => {
          "configuration" => {
            "ocr_concurrency" => 1,
            "queue_timeout_seconds" => 2.0,
            "max_reads" => 20,
            "max_input_side" => 2500,
            "det_model" => "PP-OCRv5_mobile_det"
          },
          "reads" => { "active" => 0, "rejected_busy" => 2 }
        }
      }
    )

    original = ENV.fetch("VERIFY_CONCURRENCY", nil)
    ENV["VERIFY_CONCURRENCY"] = "4"
    begin
      report = Extraction::RuntimeDependencies.new(
        config: config("paddle"),
        command_checker: FakeCommandChecker.new(%w[magick pdftoppm tesseract]),
        http_checker: checker,
        ocr_supervisor: FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "disabled"))
      ).report

      sidecar = report[:dependencies].find { |dependency| dependency[:key] == "paddle_sidecar" }
      assert report[:ok]
      assert_match(/ocr_concurrency=1/, sidecar[:detail])
      assert_match(/max_input_side=2500/, sidecar[:detail])
      assert_match(/det_model=PP-OCRv5_mobile_det/, sidecar[:detail])
      assert_match(/rejected_busy=2/, sidecar[:detail])
      assert_equal 4, report.dig(:capacity, :verify_concurrency)
      assert_equal 1, report.dig(:capacity, :ocr_concurrency)
      assert_equal 2.0, report.dig(:capacity, :queue_timeout_seconds)
      assert_equal 20, report.dig(:capacity, :max_reads)
      assert_equal 2500, report.dig(:capacity, :max_input_side)
      assert_equal "PP-OCRv5_mobile_det", report.dig(:capacity, :det_model)
      assert_equal 2, report.dig(:capacity, :rejected_busy)
      assert_equal false, report.dig(:capacity, :aligned)
      assert_match(/exceeds OCR_CONCURRENCY/, report.dig(:capacity, :warning))
    ensure
      if original.nil?
        ENV.delete("VERIFY_CONCURRENCY")
      else
        ENV["VERIFY_CONCURRENCY"] = original
      end
    end
  end

  test "defaults verification capacity to OCR capacity when no override is set" do
    checker = FakeHttpChecker.new(
      results: { "/healthz" => true, "/readyz" => true },
      json_results: {
        "/metrics" => {
          "configuration" => {
            "ocr_concurrency" => 1,
            "queue_timeout_seconds" => 2.0,
            "max_reads" => 20,
            "max_input_side" => 2500,
            "det_model" => "PP-OCRv5_mobile_det"
          },
          "reads" => { "active" => 0, "rejected_busy" => 0 }
        }
      }
    )

    original_verify = ENV.fetch("VERIFY_CONCURRENCY", nil)
    original_ocr = ENV.fetch("OCR_CONCURRENCY", nil)
    ENV.delete("VERIFY_CONCURRENCY")
    ENV.delete("OCR_CONCURRENCY")
    begin
      report = Extraction::RuntimeDependencies.new(
        config: config("paddle"),
        command_checker: FakeCommandChecker.new(%w[magick pdftoppm tesseract]),
        http_checker: checker,
        ocr_supervisor: FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "disabled"))
      ).report

      assert_equal 1, report.dig(:capacity, :verify_concurrency)
      assert_equal 1, report.dig(:capacity, :ocr_concurrency)
      assert_equal true, report.dig(:capacity, :aligned)
      assert_nil report.dig(:capacity, :warning)
    ensure
      if original_verify.nil?
        ENV.delete("VERIFY_CONCURRENCY")
      else
        ENV["VERIFY_CONCURRENCY"] = original_verify
      end
      if original_ocr.nil?
        ENV.delete("OCR_CONCURRENCY")
      else
        ENV["OCR_CONCURRENCY"] = original_ocr
      end
    end
  end

  test "skips sidecar check when tesseract is configured directly" do
    report = Extraction::RuntimeDependencies.new(
      config: config("tesseract"),
      command_checker: FakeCommandChecker.new(%w[magick pdftoppm tesseract]),
      http_checker: FakeHttpChecker.new(
        results: { "/healthz" => false, "/readyz" => false },
        json_results: { "/metrics" => nil }
      ),
      ocr_supervisor: FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "disabled"))
    ).report

    assert report[:ok]
    keys = report[:dependencies].map { |dep| dep[:key] }
    assert_not_includes keys, "paddle_sidecar"
    assert_nil report[:capacity]
  end

  test "check_ocr_ready succeeds when tesseract is available" do
    checker = FakeHttpChecker.new(
      results: { "/healthz" => false, "/readyz" => false },
      json_results: { "/metrics" => nil }
    )

    readiness = Extraction::RuntimeDependencies.new(
      config: config("tesseract"),
      command_checker: FakeCommandChecker.new(%w[tesseract]),
      http_checker: checker,
      ocr_supervisor: FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "disabled"))
    ).check_ocr_ready

    assert_predicate readiness, :ok?
    assert_nil readiness.error_message
    assert_operator readiness.latency_ms, :>=, 0
    assert_empty checker.checked
  end

  test "check_ocr_ready fails when tesseract is missing" do
    readiness = Extraction::RuntimeDependencies.new(
      config: config("tesseract"),
      command_checker: FakeCommandChecker.new([]),
      http_checker: FakeHttpChecker.new(results: {}, json_results: {}),
      ocr_supervisor: FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "disabled"))
    ).check_ocr_ready

    assert_not readiness.ok?
    assert_match(/Tesseract OCR CLI/, readiness.error_message)
  end

  test "check_ocr_ready uses the OCR gateway and supervisor for paddle" do
    checker = FakeHttpChecker.new(
      results: { "/healthz" => false },
      json_results: { "/metrics" => nil }
    )
    supervisor = FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "OCR auto-start is disabled"))

    readiness = Extraction::RuntimeDependencies.new(
      config: config("paddle"),
      command_checker: FakeCommandChecker.new(%w[tesseract]),
      http_checker: checker,
      ocr_supervisor: supervisor
    ).check_ocr_ready

    assert_not readiness.ok?
    assert_equal 1, supervisor.calls
    assert_match(/auto-start is disabled/, readiness.error_message)
  end

  test "class-level OCR readiness check is cached briefly" do
    fake = Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def check_ocr_ready
        @calls += 1
        Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: @calls, error_message: nil)
      end
    end.new
    original_build = Extraction::RuntimeDependencies.method(:build)
    Extraction::RuntimeDependencies.define_singleton_method(:build) { fake }
    Extraction::RuntimeDependencies.clear_ocr_ready_cache

    first = Extraction::RuntimeDependencies.check_ocr_ready
    second = Extraction::RuntimeDependencies.check_ocr_ready

    assert_equal 1, fake.calls
    assert_equal first, second
  ensure
    Extraction::RuntimeDependencies.clear_ocr_ready_cache
    Extraction::RuntimeDependencies.define_singleton_method(:build) { original_build.call }
  end

  private

  def config(ocr_engine)
    Config.new(
      ocr_engine: ocr_engine,
      paddle_url: "http://127.0.0.1:8765",
      ocr_auto_start: true,
      ocr_start_timeout_seconds: 0.01
    )
  end
end
