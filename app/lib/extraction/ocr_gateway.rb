# frozen_string_literal: true

require "net/http"

module Extraction
  # Small operational boundary for the OCR backend. Batch work depends on
  # trustworthy OCR, so controllers ask this gateway before admitting work
  # into the queue instead of discovering a dead sidecar after rows have
  # already been persisted.
  class OcrGateway
    Readiness = Data.define(:ok, :message) do
      def ok?
        ok
      end
    end

    class HttpChecker
      def ok?(url, path)
        uri = URI(url)
        Net::HTTP.start(
          uri.host,
          uri.port,
          open_timeout: 1,
          read_timeout: 1,
          use_ssl: uri.scheme == "https"
        ) do |http|
          http.get(path).is_a?(Net::HTTPSuccess)
        end
      rescue SystemCallError, IOError, Timeout::Error, URI::InvalidURIError
        false
      end
    end

    def self.ready
      build.ready
    end

    def self.build
      new(
        config: Rails.application.config.x.extraction,
        http_checker: HttpChecker.new,
        supervisor: OcrSupervisor.build
      )
    end

    def initialize(config:, http_checker:, supervisor:)
      @config = config
      @http_checker = http_checker
      @supervisor = supervisor
    end

    def ready
      return Readiness.new(true, "Tesseract OCR configured directly") if @config.ocr_engine == "tesseract"
      return Readiness.new(true, "OCR backend ready at #{@config.paddle_url}") if backend_ready?

      start_result = @supervisor.ensure_running
      return Readiness.new(false, start_result.message) unless start_result.ok?

      wait_until_ready(start_result)
    end

    private

    def backend_ready?
      health_path = "/healthz"
      return false unless success?(health_path)

      ready_path = "/readyz"
      success?(ready_path)
    end

    def wait_until_ready(start_result)
      deadline = monotonic_seconds + @config.ocr_start_timeout_seconds
      while monotonic_seconds < deadline
        return Readiness.new(true, "#{start_result.message}; OCR backend ready at #{@config.paddle_url}") if backend_ready?

        sleep 0.5
      end

      Readiness.new(
        false,
        "#{start_result.message}; OCR backend did not become ready within #{@config.ocr_start_timeout_seconds}s"
      )
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def success?(path)
      @http_checker.ok?(@config.paddle_url, path)
    end
  end
end
