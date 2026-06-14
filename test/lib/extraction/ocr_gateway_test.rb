# frozen_string_literal: true

require "test_helper"

class OcrGatewayTest < ActiveSupport::TestCase
  Config = Data.define(:ocr_engine, :paddle_url, :ocr_auto_start, :ocr_start_timeout_seconds)

  class FakeHttpChecker
    attr_reader :checked

    def initialize(results)
      @results = results.transform_values { |value| Array(value).dup }
      @checked = []
    end

    def ok?(url, path)
      @checked << [ url, path ]
      values = @results.fetch(path)
      return values.first if values.length == 1

      values.shift
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

  test "is ready when paddle health and readiness pass" do
    checker = FakeHttpChecker.new("/healthz" => true, "/readyz" => true)
    supervisor = FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(true, 123, "started"))
    gateway = Extraction::OcrGateway.new(
      config: config(ocr_engine: "paddle"),
      http_checker: checker,
      supervisor: supervisor
    )

    readiness = gateway.ready

    assert_predicate readiness, :ok?
    assert_equal 0, supervisor.calls
    assert_match(/ready/, readiness.message)
    assert_equal [
      [ "http://127.0.0.1:8765", "/healthz" ],
      [ "http://127.0.0.1:8765", "/readyz" ]
    ], checker.checked
  end

  test "fails closed when paddle health is unavailable" do
    checker = FakeHttpChecker.new("/healthz" => false)
    supervisor = FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "OCR auto-start is disabled"))
    gateway = Extraction::OcrGateway.new(
      config: config(ocr_engine: "paddle"),
      http_checker: checker,
      supervisor: supervisor
    )

    readiness = gateway.ready

    assert_not readiness.ok?
    assert_equal 1, supervisor.calls
    assert_match(/auto-start is disabled/, readiness.message)
    assert_equal [ [ "http://127.0.0.1:8765", "/healthz" ] ], checker.checked
  end

  test "fails closed when paddle readiness is unavailable" do
    checker = FakeHttpChecker.new("/healthz" => true, "/readyz" => false)
    supervisor = FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(false, nil, "OCR auto-start is disabled"))
    gateway = Extraction::OcrGateway.new(
      config: config(ocr_engine: "paddle"),
      http_checker: checker,
      supervisor: supervisor
    )

    readiness = gateway.ready

    assert_not readiness.ok?
    assert_equal 1, supervisor.calls
    assert_match(/auto-start is disabled/, readiness.message)
  end

  test "does not require a sidecar when tesseract is configured" do
    checker = FakeHttpChecker.new("/healthz" => false, "/readyz" => false)
    supervisor = FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(true, 123, "started"))
    gateway = Extraction::OcrGateway.new(
      config: config(ocr_engine: "tesseract"),
      http_checker: checker,
      supervisor: supervisor
    )

    readiness = gateway.ready

    assert_predicate readiness, :ok?
    assert_empty checker.checked
    assert_equal 0, supervisor.calls
  end

  test "starts local OCR and waits until it is ready" do
    checker = FakeHttpChecker.new("/healthz" => [ false, true ], "/readyz" => true)
    supervisor = FakeSupervisor.new(Extraction::OcrSupervisor::Result.new(true, 123, "OCR sidecar started"))
    gateway = Extraction::OcrGateway.new(
      config: config(ocr_engine: "paddle"),
      http_checker: checker,
      supervisor: supervisor
    )

    readiness = gateway.ready

    assert_predicate readiness, :ok?
    assert_equal 1, supervisor.calls
    assert_match(/sidecar started/, readiness.message)
    assert_equal [
      [ "http://127.0.0.1:8765", "/healthz" ],
      [ "http://127.0.0.1:8765", "/healthz" ],
      [ "http://127.0.0.1:8765", "/readyz" ]
    ], checker.checked
  end

  private

  def config(ocr_engine:)
    Config.new(
      ocr_engine: ocr_engine,
      paddle_url: "http://127.0.0.1:8765",
      ocr_auto_start: true,
      ocr_start_timeout_seconds: 0.01
    )
  end
end
