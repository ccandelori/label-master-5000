# frozen_string_literal: true

require "test_helper"

class RuntimeDependenciesControllerTest < ActionDispatch::IntegrationTest
  class FakeRuntimeDependencies
    def initialize(report)
      @report = report
    end

    def report
      @report
    end
  end

  def with_runtime_dependency_report(report, readiness)
    original_build = Extraction::RuntimeDependencies.method(:build)
    original_ready = Extraction::RuntimeDependencies.method(:check_ocr_ready)
    fake = FakeRuntimeDependencies.new(report)
    Extraction::RuntimeDependencies.define_singleton_method(:build) { fake }
    Extraction::RuntimeDependencies.define_singleton_method(:check_ocr_ready) { readiness }
    yield
  ensure
    Extraction::RuntimeDependencies.define_singleton_method(:build) { original_build.call }
    Extraction::RuntimeDependencies.define_singleton_method(:check_ocr_ready) { original_ready.call }
  end

  test "dependency health endpoint returns structured JSON" do
    report = { ok: true, dependencies: [ { key: "magick", available: true } ] }
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 5, error_message: nil)
    with_runtime_dependency_report(report, readiness) do
      get runtime_dependencies_health_check_path
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_includes body.keys, "ok"
    assert_includes body.keys, "dependencies"
    assert_equal true, body.dig("ocr_ready", "ready")
  end

  test "dependency health endpoint reports service unavailable when required dependencies are missing" do
    report = { ok: false, dependencies: [ { key: "tesseract", available: false } ] }
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 5, error_message: nil)
    with_runtime_dependency_report(report, readiness) do
      get runtime_dependencies_health_check_path
    end

    assert_response :service_unavailable
    assert_equal false, JSON.parse(response.body).fetch("ok")
  end

  test "dependency health endpoint reports service unavailable when OCR is not ready" do
    report = { ok: true, dependencies: [ { key: "tesseract", available: true } ] }
    readiness = Extraction::RuntimeDependencies::OcrReadiness.new(
      ready: false,
      latency_ms: 5,
      error_message: "Tesseract OCR CLI is missing from PATH"
    )
    with_runtime_dependency_report(report, readiness) do
      get runtime_dependencies_health_check_path
    end

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("ok")
    assert_equal "Tesseract OCR CLI is missing from PATH", body.dig("ocr_ready", "error_message")
  end
end
