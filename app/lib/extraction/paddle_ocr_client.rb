# frozen_string_literal: true

require "net/http"

module Extraction
  # Word-geometry OCR over the PaddleOCR sidecar (ocr_service/). Speaks
  # the same contract as OcrClient: read(data:, content_type:) returning
  # Pages of Words in the raster's pixel space. Paddle's detector reads
  # the stylized, inverse, and rotated type that blinds Tesseract; its
  # entries are text lines rather than words, which the fuzzy matcher
  # tokenizes itself. Artwork only ever travels to localhost (or the
  # deployment's internal network) - never a third party.
  class PaddleOcrClient
    PDF_CONTENT_TYPE = "application/pdf"

    class << self
      def with_read_slot
        token = read_slots.pop
        yield
      ensure
        read_slots << token if token
      end

      private

      def read_slots
        @read_slots ||= begin
          slots = Queue.new
          Integer(ENV.fetch("OCR_CONCURRENCY", "1")).times { slots << true }
          slots
        end
      end
    end

    def initialize(base_url:, pdftoppm:, dpi:, timeout_seconds:, attempts:, backoff_seconds:)
      @base_url = URI(base_url)
      @pdftoppm = pdftoppm
      @dpi = dpi
      @timeout_seconds = timeout_seconds
      @attempts = attempts
      @backoff_seconds = backoff_seconds
    end

    def self.build
      config = Rails.application.config.x.extraction
      new(
        base_url: config.paddle_url,
        pdftoppm: "pdftoppm",
        dpi: config.ocr_dpi,
        timeout_seconds: config.paddle_timeout_seconds,
        attempts: 3,
        backoff_seconds: 4
      )
    end

    def read(data:, content_type:)
      if content_type == PDF_CONTENT_TYPE
        PdfPages.rasterize(data: data, dpi: @dpi, pdftoppm: @pdftoppm) do |pages|
          pages.map { |path, number| read_image(File.binread(path), number) }
        end
      else
        [ read_image(data, 1) ]
      end
    end

    # Pure response mapping, exposed for tests that have no sidecar.
    def self.parse_page(payload, page_number:)
      width = payload["width"]
      height = payload["height"]
      raise OcrError, "sidecar response carried no page dimensions" unless width.is_a?(Integer) && height.is_a?(Integer)

      words = Array(payload["words"]).filter_map do |word|
        text = word["text"].to_s.strip
        next if text.empty?

        OcrClient.build_word(
          text: text,
          x: Integer(word["x"]), y: Integer(word["y"]),
          width: Integer(word["width"]), height: Integer(word["height"]),
          confidence: Float(word["confidence"], exception: false)
        )
      end

      OcrClient::Page.new(number: page_number, width: width, height: height, words: words)
    end

    private

    # The sidecar recycles its worker periodically to bound PaddleOCR's
    # memory growth; a read landing in the reload window is refused, so
    # connection failures retry with a warning before the last error
    # propagates (and the engine-level fallback takes over). Only
    # connection failures and explicit busy responses: retrying a timed-out
    # inference would re-submit the same expensive work to a worker that is
    # already struggling.
    def read_image(data, page_number)
      attempt = 0
      begin
        attempt += 1
        attempt_read(data, page_number)
      rescue OcrConnectionError, OcrBackpressureError => e
        raise e if attempt >= @attempts

        backoff_seconds = retry_delay(error: e, attempt: attempt)
        instrument_retry(error: e, attempt: attempt, backoff_seconds: backoff_seconds)
        Rails.logger.warn(JSON.generate({
          event: "paddle_read_retry", attempt: attempt, of: @attempts,
          backoff_seconds: backoff_seconds, error_class: e.class.name,
          error: e.message.to_s.first(160)
        }))
        sleep(backoff_seconds)
        retry
      end
    end

    def attempt_read(data, page_number)
      response = self.class.with_read_slot { post_read(data) }
      if response.code.to_i == 429
        raise OcrBackpressureError.new(
          "ocr sidecar busy at #{@base_url}: #{response.body.to_s.first(200)}",
          retry_after_seconds: retry_after_seconds(response)
        )
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise OcrError, "ocr sidecar responded #{response.code}: #{response.body.to_s.first(200)}"
      end

      self.class.parse_page(JSON.parse(response.body), page_number: page_number)
    rescue JSON::ParserError => e
      raise OcrError, "ocr sidecar returned invalid JSON: #{e.message.first(200)}"
    end

    def post_read(data)
      Net::HTTP.start(
        @base_url.host, @base_url.port,
        open_timeout: 2, read_timeout: @timeout_seconds
      ) do |http|
        http.post("/read", data, { "Content-Type" => "application/octet-stream" })
      end
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout => e
      raise OcrConnectionError, "ocr sidecar unreachable at #{@base_url}: #{e.class.name}: #{e.message.to_s.first(120)}"
    rescue SystemCallError, IOError, Timeout::Error => e
      raise OcrError, "ocr sidecar read failed at #{@base_url}: #{e.class.name}: #{e.message.to_s.first(120)}"
    end

    def retry_delay(error:, attempt:)
      if error.is_a?(OcrBackpressureError) && !error.retry_after_seconds.nil?
        return error.retry_after_seconds
      end

      @backoff_seconds * attempt
    end

    def retry_after_seconds(response)
      seconds = Float(response["Retry-After"].to_s, exception: false)
      return nil if seconds.nil? || seconds.negative?

      seconds
    end

    def instrument_retry(error:, attempt:, backoff_seconds:)
      ActiveSupport::Notifications.instrument(
        "verification.ocr_backpressure.label_verifier",
        error_class: error.class.name,
        attempt: attempt,
        of: @attempts,
        backoff_seconds: backoff_seconds,
        busy: error.is_a?(OcrBackpressureError)
      )
    end
  end
end
