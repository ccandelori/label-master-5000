# frozen_string_literal: true

require "net/http"
require "open3"
require "uri"

module Extraction
  # Production readiness check for external OCR and image-processing
  # dependencies that the verification pipeline shells out to or calls over
  # localhost. The check is read-only and returns structured data for health
  # endpoints, benchmarks, and deploy smoke tests.
  class RuntimeDependencies
    Dependency = Data.define(:key, :label, :required, :available, :detail) do
      def to_h
        {
          key: key,
          label: label,
          required: required,
          available: available,
          detail: detail
        }
      end
    end

    OcrReadiness = Data.define(:ready, :latency_ms, :error_message) do
      def ready?
        ready
      end

      def ok?
        ready
      end

      def to_h
        {
          ready: ready,
          latency_ms: latency_ms,
          error_message: error_message
        }
      end
    end

    class CommandChecker
      def available?(command)
        _stdout, _stderr, status = Open3.capture3("which", command)
        status.success?
      rescue SystemCallError
        false
      end
    end

    class HttpChecker
      def ok?(url, path)
        response = response_for(url, path)
        response.is_a?(Net::HTTPSuccess)
      rescue SystemCallError, IOError, Timeout::Error, URI::InvalidURIError
        false
      end

      def json(url, path)
        response = response_for(url, path)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError, SystemCallError, IOError, Timeout::Error, URI::InvalidURIError
        nil
      end

      private

      def response_for(url, path)
        uri = URI(url)
        Net::HTTP.start(
          uri.host, uri.port,
          open_timeout: 1, read_timeout: 1, use_ssl: uri.scheme == "https"
        ) do |http|
          http.get(path)
        end
      end
    end

    def self.build
      new(
        config: Rails.application.config.x.extraction,
        command_checker: CommandChecker.new,
        http_checker: HttpChecker.new,
        ocr_supervisor: OcrSupervisor.build
      )
    end

    def self.check_ocr_ready
      key = ocr_ready_cache_key
      cached = @ocr_ready_cache
      return cached.fetch(:value) if cached && cached.fetch(:key) == key && cached.fetch(:expires_at) > monotonic_seconds

      value = build.check_ocr_ready
      @ocr_ready_cache = { key: key, value: value, expires_at: monotonic_seconds + 30.0 }
      value
    end

    def self.clear_ocr_ready_cache
      @ocr_ready_cache = nil
    end

    def self.ocr_ready_cache_key
      config = Rails.application.config.x.extraction
      "extraction/ocr_ready/#{config.ocr_engine}/#{config.paddle_url}"
    end
    private_class_method :ocr_ready_cache_key

    def self.monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_seconds

    def initialize(config:, command_checker:, http_checker:, ocr_supervisor:)
      @config = config
      @command_checker = command_checker
      @http_checker = http_checker
      @ocr_supervisor = ocr_supervisor
    end

    def report
      deps = dependencies
      report = {
        ok: deps.none? { |dep| dep.required && !dep.available },
        dependencies: deps.map(&:to_h)
      }
      capacity = capacity_report
      report[:capacity] = capacity if capacity
      report
    end

    def check_ocr_ready
      started = monotonic_ms
      readiness = if @config.ocr_engine == "tesseract"
        tesseract_readiness
      else
        paddle_readiness
      end

      OcrReadiness.new(
        ready: readiness.ok?,
        latency_ms: monotonic_ms - started,
        error_message: readiness.ok? ? nil : readiness.message
      )
    end

    private

    def dependencies
      command_dependencies + paddle_dependencies
    end

    def command_dependencies
      [
        required_command_dependency("magick", "ImageMagick CLI for image dimensions and crops"),
        required_command_dependency("pdftoppm", "Poppler pdftoppm for PDF rasterization"),
        required_command_dependency("tesseract", "Tesseract OCR CLI fallback")
      ]
    end

    def required_command_dependency(command, label)
      available = @command_checker.available?(command)
      Dependency.new(
        key: command,
        label: label,
        required: true,
        available: available,
        detail: available ? "available on PATH" : "missing from PATH"
      )
    end

    def paddle_dependencies
      return [] unless @config.ocr_engine == "paddle"

      health_available = @http_checker.ok?(@config.paddle_url, "/healthz")
      readiness_available = health_available && @http_checker.ok?(@config.paddle_url, "/readyz")
      @paddle_ready = health_available && readiness_available
      metrics = readiness_available ? paddle_metrics : nil
      [ Dependency.new(
        key: "paddle_sidecar",
        label: "PaddleOCR sidecar health endpoint",
        required: true,
        available: health_available && readiness_available,
        detail: paddle_detail(health_available, readiness_available, metrics)
      ) ]
    end

    def paddle_detail(health_available, readiness_available, metrics)
      return "unreachable at #{@config.paddle_url}/healthz" unless health_available
      return "not ready at #{@config.paddle_url}/readyz" unless readiness_available

      return "healthy and ready at #{@config.paddle_url}" unless metrics

      config = metrics.fetch("configuration", {})
      reads = metrics.fetch("reads", {})
      "healthy and ready at #{@config.paddle_url}; " \
        "ocr_concurrency=#{config["ocr_concurrency"]}, " \
        "max_input_side=#{config["max_input_side"]}, " \
        "det_model=#{config["det_model"]}, " \
        "active=#{reads["active"]}, rejected_busy=#{reads["rejected_busy"]}"
    end

    def capacity_report
      return nil unless @config.ocr_engine == "paddle" && @paddle_ready

      metrics = paddle_metrics
      ocr_concurrency = metrics&.dig("configuration", "ocr_concurrency")
      verify_concurrency = configured_verify_concurrency(ocr_concurrency)
      {
        verify_concurrency: verify_concurrency,
        ocr_concurrency: ocr_concurrency,
        queue_timeout_seconds: metrics&.dig("configuration", "queue_timeout_seconds"),
        max_reads: metrics&.dig("configuration", "max_reads"),
        max_input_side: metrics&.dig("configuration", "max_input_side"),
        det_model: metrics&.dig("configuration", "det_model"),
        rejected_busy: metrics&.dig("reads", "rejected_busy"),
        active: metrics&.dig("reads", "active"),
        aligned: aligned_capacity?(verify_concurrency, ocr_concurrency),
        warning: capacity_warning(verify_concurrency, ocr_concurrency)
      }.compact
    end

    def paddle_metrics
      @paddle_metrics ||= @http_checker.json(@config.paddle_url, "/metrics")
    end

    def integer_env(key)
      Integer(ENV.fetch(key, nil), exception: false)
    end

    def configured_verify_concurrency(ocr_concurrency)
      integer_env("VERIFY_CONCURRENCY") || integer_env("OCR_CONCURRENCY") || ocr_concurrency
    end

    def aligned_capacity?(verify_concurrency, ocr_concurrency)
      return nil if verify_concurrency.nil? || ocr_concurrency.nil?

      verify_concurrency <= ocr_concurrency
    end

    def capacity_warning(verify_concurrency, ocr_concurrency)
      return nil if verify_concurrency.nil? || ocr_concurrency.nil? || verify_concurrency <= ocr_concurrency

      "VERIFY_CONCURRENCY=#{verify_concurrency} exceeds OCR_CONCURRENCY=#{ocr_concurrency}; " \
        "busy OCR reads will retry instead of falling back"
    end

    def tesseract_readiness
      if @command_checker.available?("tesseract")
        OcrGateway::Readiness.new(true, "Tesseract OCR available on PATH")
      else
        OcrGateway::Readiness.new(false, "Tesseract OCR CLI is missing from PATH")
      end
    end

    def paddle_readiness
      OcrGateway.new(
        config: @config,
        http_checker: @http_checker,
        supervisor: @ocr_supervisor
      ).ready
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    end
  end
end
