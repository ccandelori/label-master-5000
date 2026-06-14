# frozen_string_literal: true

require "open3"

module Extraction
  # Image transforms for OCR enrichment, shelled to ImageMagick with bytes
  # on stdin/stdout - no temp files, no new gem. Every function returns
  # PNG bytes; failures raise OcrError (callers treat enrichment as
  # best-effort and the base pass as mandatory).
  module ImageVariants
    module_function

    def upscale(data, factor:)
      run!(data, "-resize", "#{(factor * 100).to_i}%")
    end

    # Grayscale inversion recovers light-on-dark print for engines that
    # prefer dark-on-light.
    def invert(data)
      run!(data, "-colorspace", "gray", "-negate")
    end

    def rotate(data, degrees:)
      run!(data, "-rotate", degrees.to_s)
    end

    def enhance_contrast(data)
      run!(data, "-colorspace", "gray", "-auto-level", "-contrast-stretch", "2%x2%")
    end

    # rect is [x, y, width, height] in the image's own pixel space.
    def crop(data, rect:, upscale_factor:)
      x, y, w, h = rect.map(&:round)
      run!(data, "-crop", "#{w}x#{h}+#{x}+#{y}", "+repage", "-resize", "#{(upscale_factor * 100).to_i}%")
    end

    # [width, height] of the image bytes.
    def dimensions(data)
      stdout, stderr, status = Open3.capture3("magick", "identify", "-format", "%w %h", "-", stdin_data: data, binmode: true)
      raise OcrError, "magick identify failed: #{stderr.to_s.strip.first(200)}" unless status.success?

      stdout.split(" ").first(2).map { |v| Integer(v) }
    rescue Errno::ENOENT => e
      raise OcrError, "imagemagick is not installed: #{e.message}"
    end

    def run!(data, *args)
      stdout, stderr, status = Open3.capture3("magick", "-", *args, "png:-", stdin_data: data, binmode: true)
      raise OcrError, "magick failed: #{stderr.to_s.strip.first(200)}" unless status.success?

      stdout
    rescue Errno::ENOENT => e
      raise OcrError, "imagemagick is not installed: #{e.message}"
    end
  end
end
