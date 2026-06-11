# frozen_string_literal: true

require "open3"
require "tmpdir"

module Extraction
  # Rasterizes PDF artwork into per-page PNGs for the OCR engines.
  # Yields [path, page_number] pairs inside a temp directory that is
  # cleaned up when the block returns.
  module PdfPages
    module_function

    def rasterize(data:, dpi:, pdftoppm:)
      Dir.mktmpdir("ocr-artwork") do |dir|
        pdf_path = File.join(dir, "artwork.pdf")
        File.binwrite(pdf_path, data)
        run!(pdftoppm, "-r", dpi.to_s, "-png", pdf_path, File.join(dir, "page"))

        # pdftoppm zero-pads page numbers when the document is long enough
        # (page-1.png vs page-01.png), so sort numerically.
        pngs = Dir[File.join(dir, "page-*.png")].sort_by { |path| path[/(\d+)\.png\z/, 1].to_i }
        raise OcrError, "pdftoppm produced no page images" if pngs.empty?

        yield pngs.each_with_index.map { |path, index| [ path, index + 1 ] }
      end
    end

    # Page-object count from the raw bytes. Crude but dependency-free; the
    # page cap exists to protect the latency budget, not for exactness.
    def page_count(data)
      count = data.scan(%r{/Type\s*/Page[^s]}).size
      count.positive? ? count : 1
    end

    def run!(*command)
      _stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        raise OcrError,
              "#{command.first} exited #{status.exitstatus}: #{stderr.to_s.strip.first(300)}"
      end
    rescue Errno::ENOENT => e
      raise OcrError, "#{command.first} is not installed: #{e.message}"
    end
  end
end
