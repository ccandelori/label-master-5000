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

        OcrClient::Word.new(
          text: text,
          x: Integer(word["x"]), y: Integer(word["y"]),
          width: Integer(word["width"]), height: Integer(word["height"])
        )
      end

      OcrClient::Page.new(number: page_number, width: width, height: height, words: words)
    end

    private

    # The sidecar recycles its worker periodically to bound PaddleOCR's
    # memory growth; a read landing in the reload window is refused, so
    # transient failures retry with a warning before the last error
    # propagates (and the engine-level fallback takes over).
    def read_image(data, page_number)
      attempt = 0
      begin
        attempt += 1
        attempt_read(data, page_number)
      rescue OcrError => e
        raise e if attempt >= @attempts

        Rails.logger.warn(JSON.generate({
          event: "paddle_read_retry", attempt: attempt, of: @attempts,
          backoff_seconds: @backoff_seconds * attempt, error: e.message.to_s.first(160)
        }))
        sleep(@backoff_seconds * attempt)
        retry
      end
    end

    def attempt_read(data, page_number)
      response = post_read(data)
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
    rescue SystemCallError, IOError, Timeout::Error => e
      raise OcrError, "ocr sidecar unreachable at #{@base_url}: #{e.class.name}: #{e.message.to_s.first(120)}"
    end
  end
end
