# frozen_string_literal: true

require "open3"
require "tempfile"
require "tmpdir"

module Extraction
  # Word-level OCR over the Tesseract CLI. The localization counterpart to
  # the vision extractor: the model decides WHAT each field says, this
  # connector reports WHERE every word sits, in the pixel space of the
  # rasterized page. PDFs are rasterized with pdftoppm first, one OCR pass
  # per page. Runs entirely on this host - artwork never leaves the system.
  class OcrClient
    Word = Data.define(:text, :x, :y, :width, :height)
    Page = Data.define(:number, :width, :height, :words)

    PDF_CONTENT_TYPE = "application/pdf"
    # Tesseract TSV hierarchy levels (level column).
    TSV_PAGE_LEVEL = 1
    TSV_WORD_LEVEL = 5
    TSV_COLUMNS = 12

    def initialize(tesseract:, pdftoppm:, dpi:)
      @tesseract = tesseract
      @pdftoppm = pdftoppm
      @dpi = dpi
    end

    def self.build
      new(
        tesseract: "tesseract",
        pdftoppm: "pdftoppm",
        dpi: Rails.application.config.x.extraction.ocr_dpi
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
          words << Word.new(text: text, x: left, y: top, width: w, height: h) unless text.empty?
        end
      end

      raise OcrError, "tesseract TSV reported no page dimensions" if width.nil? || height.nil?

      Page.new(number: page_number, width: width, height: height, words: words)
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
      Dir.mktmpdir("ocr-artwork") do |dir|
        pdf_path = File.join(dir, "artwork.pdf")
        File.binwrite(pdf_path, data)
        run!(@pdftoppm, "-r", @dpi.to_s, "-png", pdf_path, File.join(dir, "page"))

        # pdftoppm zero-pads page numbers when the document is long enough
        # (page-1.png vs page-01.png), so sort numerically.
        pngs = Dir[File.join(dir, "page-*.png")].sort_by { |path| path[/(\d+)\.png\z/, 1].to_i }
        raise OcrError, "pdftoppm produced no page images" if pngs.empty?

        pngs.each_with_index.map { |path, index| ocr_file(path, index + 1) }
      end
    end

    def ocr_file(path, page_number)
      tsv = run!(@tesseract, path, "stdout", "tsv")
      self.class.parse_tsv(tsv, page_number: page_number)
    end

    def run!(*command)
      stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        raise OcrError,
              "#{command.first} exited #{status.exitstatus}: #{stderr.to_s.strip.first(300)}"
      end

      stdout
    rescue Errno::ENOENT => e
      raise OcrError, "#{command.first} is not installed: #{e.message}"
    end
  end
end
