# frozen_string_literal: true

require "tempfile"
require "tmpdir"

module Extraction
  # Word-level OCR over the Tesseract CLI. The localization counterpart to
  # the vision extractor: the model decides WHAT each field says, this
  # connector reports WHERE every word sits, in the pixel space of the
  # rasterized page. PDFs are rasterized with pdftoppm first, one OCR pass
  # per page. Runs entirely on this host - artwork never leaves the system.
  class OcrClient
    Word = Data.define(:text, :x, :y, :width, :height) do
      def confidence
        nil
      end
    end
    WordWithConfidence = Data.define(:text, :x, :y, :width, :height, :confidence)
    Page = Data.define(:number, :width, :height, :words)

    PDF_CONTENT_TYPE = "application/pdf"
    # Tesseract TSV hierarchy levels (level column).
    TSV_PAGE_LEVEL = 1
    TSV_WORD_LEVEL = 5
    TSV_COLUMNS = 12

    def initialize(tesseract:, pdftoppm:, dpi:, timeout_seconds:)
      @tesseract = tesseract
      @pdftoppm = pdftoppm
      @dpi = dpi
      @timeout_seconds = timeout_seconds
    end

    def self.build
      config = Rails.application.config.x.extraction
      new(
        tesseract: "tesseract",
        pdftoppm: "pdftoppm",
        dpi: config.ocr_dpi,
        timeout_seconds: config.ocr_timeout_seconds
      )
    end

    # data: raw artwork bytes. Returns one Page per artwork page; each
    # word box is in pixels of that page's raster, (0, 0) at top-left -
    # the page's width/height are the coordinate basis for its boxes.
    def read(data:, content_type:)
      if content_type == PDF_CONTENT_TYPE
        read_pdf(data)
      else
        read_image(data)
      end
    end

    # Pure TSV-to-Page mapping, exposed so parsing is testable without the
    # binary. Tesseract TSV columns: level, page_num, block_num, par_num,
    # line_num, word_num, left, top, width, height, conf, text.
    def self.parse_tsv(tsv, page_number:)
      width = nil
      height = nil
      words = []

      tsv.lines.drop(1).each do |line|
        # Non-word rows end in an empty text column; the -1 limit keeps
        # that trailing empty field so the column count stays uniform.
        cols = line.chomp.split("\t", -1)
        next if cols.size < TSV_COLUMNS

        level = Integer(cols[0], exception: false)
        left, top, w, h = cols[6..9].map { |c| Integer(c, exception: false) }
        next if [ left, top, w, h ].any?(&:nil?)

        case level
        when TSV_PAGE_LEVEL
          width = w
          height = h
        when TSV_WORD_LEVEL
          text = cols[11].to_s.strip
          confidence = Float(cols[10], exception: false)
          unless text.empty?
            words << build_word(text: text, x: left, y: top, width: w, height: h, confidence: confidence)
          end
        end
      end

      raise OcrError, "tesseract TSV reported no page dimensions" if width.nil? || height.nil?

      Page.new(number: page_number, width: width, height: height, words: words)
    end

    def self.build_word(text:, x:, y:, width:, height:, confidence:)
      return Word.new(text: text, x: x, y: y, width: width, height: height) if confidence.nil? || confidence.negative?

      WordWithConfidence.new(
        text: text,
        x: x,
        y: y,
        width: width,
        height: height,
        confidence: confidence
      )
    end

    private

    def read_image(data)
      Tempfile.create([ "ocr-artwork", ".img" ], binmode: true) do |file|
        file.write(data)
        file.flush
        [ ocr_file(file.path, 1) ]
      end
    end

    def read_pdf(data)
      PdfPages.rasterize(data: data, dpi: @dpi, pdftoppm: @pdftoppm) do |pages|
        pages.map { |path, number| ocr_file(path, number) }
      end
    end

    def ocr_file(path, page_number)
      tsv = run!(@tesseract, path, "stdout", "tsv")
      self.class.parse_tsv(tsv, page_number: page_number)
    end

    def run!(*command)
      stdout, stderr, status = run_with_timeout(command)
      unless status.success?
        raise OcrError,
              "#{command.first} exited #{status.exitstatus}: #{stderr.to_s.strip.first(300)}"
      end

      stdout
    rescue Errno::ENOENT => e
      raise OcrError, "#{command.first} is not installed: #{e.message}"
    end

    def run_with_timeout(command)
      Tempfile.create("ocr-stdout", binmode: true) do |stdout_file|
        Tempfile.create("ocr-stderr", binmode: true) do |stderr_file|
          pid = Process.spawn(*command, out: stdout_file.path, err: stderr_file.path)
          status = wait_for_process(pid, command)
          stdout_file.rewind
          stderr_file.rewind
          return [ stdout_file.read, stderr_file.read, status ]
        end
      end
    end

    def wait_for_process(pid, command)
      deadline = monotonic_seconds + @timeout_seconds.to_f

      loop do
        waited = Process.waitpid(pid, Process::WNOHANG)
        return $? if waited

        if monotonic_seconds >= deadline
          terminate_process(pid)
          raise OcrError, "#{command.first} timed out after #{@timeout_seconds}s"
        end

        sleep 0.01
      end
    end

    def terminate_process(pid)
      signal_process("TERM", pid)
      sleep 0.05
      signal_process("KILL", pid)
      reap_process(pid)
    end

    def signal_process(signal, pid)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end

    def reap_process(pid)
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end

    def monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
