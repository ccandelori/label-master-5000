# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

# Reads TTB-style application PDFs into the row shape Batch can persist.
# The original PDF is retained for audit, while only rendered label pages
# are attached as artwork so verification does not match against form text.
module ApplicationPdfIngest
  PDF_CONTENT_TYPES = %w[application/pdf application/x-pdf].freeze
  PDF_EXTENSION = /\.pdf\z/i
  DEFAULT_DPI = 160

  Source = Data.define(:path, :filename, :content_type) do
    def self.from_path(path)
      pathname = Pathname(path)
      new(path: pathname, filename: pathname.basename.to_s, content_type: "application/pdf")
    end

    def self.from_upload(upload)
      new(path: Pathname(upload.tempfile.path), filename: upload.original_filename, content_type: upload.content_type)
    end
  end

  BinaryAttachment = Data.define(:data, :filename, :content_type)
  Row = Data.define(:row_number, :attributes, :application_pdf, :artworks)
  Result = Data.define(:rows, :errors) do
    def valid?
      errors.empty?
    end
  end

  module_function

  def parse(sources:, manifest_text: nil)
    errors = []
    manifest = parse_manifest(manifest_text)
    errors.concat(manifest.errors)
    return Result.new(rows: [], errors: errors) if errors.any?

    rows = []
    sources.each_with_index do |source, index|
      row_number = index + 1
      source_errors = validate_source(source, row_number)
      if source_errors.any?
        errors.concat(source_errors)
        next
      end

      row = row_for(source: source, row_number: row_number, manifest_records: manifest.records)
      if row.is_a?(BatchIngest::RowError)
        errors << row
      else
        rows << row
      end
    end

    Result.new(rows: rows, errors: errors)
  end

  Manifest = Data.define(:records, :errors)

  def parse_manifest(manifest_text)
    text = manifest_text.to_s.strip
    return Manifest.new(records: [], errors: []) if text.empty?

    payload = JSON.parse(text)
    unless payload.is_a?(Array)
      return Manifest.new(
        records: [],
        errors: [
          BatchIngest::RowError.new(
            row_number: nil,
            kind: :malformed_manifest,
            message: "Manifest JSON must be an array of application PDF records"
          )
        ]
      )
    end

    Manifest.new(records: payload.select { |record| record.is_a?(Hash) }, errors: [])
  rescue JSON::ParserError
    Manifest.new(
      records: [],
      errors: [
        BatchIngest::RowError.new(
          row_number: nil,
          kind: :malformed_manifest,
          message: "The manifest file could not be read as JSON"
        )
      ]
    )
  end

  def validate_source(source, row_number)
    errors = []
    unless source.filename.to_s.match?(PDF_EXTENSION) && PDF_CONTENT_TYPES.include?(source.content_type.to_s)
      errors << BatchIngest::RowError.new(
        row_number: row_number,
        kind: :invalid_pdf,
        message: "Row #{row_number}: #{source.filename} must be a PDF"
      )
    end
    unless source.path.exist?
      errors << BatchIngest::RowError.new(
        row_number: row_number,
        kind: :missing_pdf,
        message: "Row #{row_number}: #{source.filename} could not be read"
      )
    end
    errors
  end

  def row_for(source:, row_number:, manifest_records:)
    text = extract_text(source.path)
    page_count = page_count_for(source.path)
    record = manifest_record_for(source, manifest_records, text)
    artworks = render_label_artworks(source: source, page_count: page_count)
    return no_label_artwork_error(source, row_number) if artworks.empty?

    Row.new(
      row_number: row_number,
      attributes: attributes_for(text: text, record: record, source: source),
      application_pdf: BinaryAttachment.new(
        data: source.path.binread,
        filename: source.filename,
        content_type: "application/pdf"
      ),
      artworks: artworks
    )
  rescue PdfCommandError => e
    BatchIngest::RowError.new(row_number: row_number, kind: :pdf_processing_failed,
                              message: "Row #{row_number}: #{source.filename} could not be processed: #{e.message}")
  end

  def no_label_artwork_error(source, row_number)
    BatchIngest::RowError.new(
      row_number: row_number,
      kind: :missing_label_artwork,
      message: "Row #{row_number}: #{source.filename} did not contain label artwork pages"
    )
  end

  def attributes_for(text:, record:, source:)
    class_type = presence(record&.fetch("classTypeDescription", nil)) || class_type_from(text)
    {
      serial_number: serial_number_from(text) || ttb_id_for(source: source, text: text, record: record),
      beverage_type: beverage_type_for(class_type),
      imported: imported?(class_type),
      brand_name: brand_name_from(text) || presence(record&.fetch("brandName", nil)) || source.filename.sub(PDF_EXTENSION, ""),
      fanciful_name: fanciful_name_from(text) || presence(record&.fetch("fancifulName", nil)),
      applicant_name_address: applicant_name_address_from(text) || "Not stated on application",
      alcohol_content: nil,
      net_contents: ColaSampleIngest::NET_CONTENTS_SENTINEL,
      country_of_origin: imported?(class_type) ? "Not stated on application" : nil,
      container_embossed_info: container_embossed_info_from(text),
      varietals: [],
      appellation: nil,
      vintage_year: nil,
      declared_class_type: class_type,
      actual_alcohol_content: nil,
      contains_fd_c_yellow_5: nil,
      contains_cochineal_carmine: nil,
      contains_sulfites_10ppm: nil,
      contains_saccharin: nil,
      contains_aspartame: nil,
      contains_added_coloring: nil
    }
  end

  def beverage_type_for(class_type)
    ColaSampleIngest.beverage_type_for({ "class_type" => class_type }).presence || "spirits"
  end

  def imported?(class_type)
    class_type.to_s.match?(/\bIMPORTED\b/i)
  end

  def extract_text(path)
    out, err, status = Open3.capture3("pdftotext", "-layout", path.to_s, "-")
    raise PdfCommandError, err.presence || "pdftotext exited #{status.exitstatus}" unless status.success?

    out
  end

  def page_count_for(path)
    out, err, status = Open3.capture3("pdfinfo", path.to_s)
    raise PdfCommandError, err.presence || "pdfinfo exited #{status.exitstatus}" unless status.success?

    Integer(out[/^Pages:\s+(\d+)/, 1])
  rescue ArgumentError, TypeError
    raise PdfCommandError, "page count was not present"
  end

  def render_label_artworks(source:, page_count:)
    return [] if page_count < 2

    Dir.mktmpdir("application-pdf-ingest") do |dir|
      (2..page_count).map.with_index do |page, index|
        rendered = render_page(path: source.path, page: page, dir: Pathname(dir))
        cropped = crop_label_page(path: rendered, page_index: index, dir: Pathname(dir))
        BinaryAttachment.new(
          data: cropped.binread,
          filename: "#{source.filename.sub(PDF_EXTENSION, '')}-label-#{index + 1}.png",
          content_type: "image/png"
        )
      end
    end
  end

  def render_page(path:, page:, dir:)
    prefix = dir.join("page")
    _out, err, status = Open3.capture3(
      "pdftoppm", "-png", "-r", DEFAULT_DPI.to_s, "-f", page.to_s, "-l", page.to_s, path.to_s, prefix.to_s
    )
    raise PdfCommandError, err.presence || "pdftoppm exited #{status.exitstatus}" unless status.success?

    rendered = dir.join("page-#{page}.png")
    raise PdfCommandError, "rendered page #{page} was not created" unless rendered.exist?

    rendered
  end

  def crop_label_page(path:, page_index:, dir:)
    output = dir.join("label-#{page_index + 1}.png")
    crop = page_index.zero? ? "100%x65%+0+0" : "100%x92%+0+0"
    _out, err, status = Open3.capture3(
      "magick", path.to_s, "-gravity", "South", "-crop", crop, "+repage", output.to_s
    )
    raise PdfCommandError, err.presence || "magick exited #{status.exitstatus}" unless status.success?

    output
  end

  def manifest_record_for(source, records, text)
    ttb_id = ttb_id_for(source: source, text: text, record: nil)
    records.find do |record|
      File.basename(record["pdfPath"].to_s) == source.filename ||
        record["ttbId"].to_s == ttb_id
    end
  end

  def ttb_id_for(source:, text:, record:)
    presence(record&.fetch("ttbId", nil)) || source.filename[/\A(\d{8,})/, 1] || text[/TTB ID\s+(\d{8,})/m, 1]
  end

  def serial_number_from(text)
    lines = text.lines
    start = lines.find_index { |line| line.include?("4. SERIAL NUMBER") }
    return nil if start.nil?

    lines.drop(start + 1).first(8).filter_map do |line|
      serial_column = line[0, 32].to_s
      token = serial_column.strip[/\A([A-Z0-9][A-Z0-9-]{2,})\b/, 1]
      next if token.nil? || %w[WINE DISTILLED MALT].include?(token)

      token
    end.first
  end

  def brand_name_from(text)
    value_after_heading(text, "6. BRAND NAME")
  end

  def fanciful_name_from(text)
    value = value_after_heading(text, "7. FANCIFUL NAME")
    return nil if value.to_s.start_with?("9. FORMULA")

    value
  end

  def value_after_heading(text, heading)
    lines = text.lines
    index = lines.find_index { |line| line.include?(heading) }
    return nil if index.nil?

    lines.drop(index + 1).each do |line|
      value = presence(line)
      next if value.nil?
      return nil if value.match?(/\A\d+\./)

      return value
    end
    nil
  end

  def applicant_name_address_from(text)
    lines = text.lines
    start = lines.find_index { |line| line.include?("8. NAME AND ADDRESS OF APPLICANT") }
    stop = lines.find_index { |line| line.include?("6. BRAND NAME") } || lines.size
    return nil if start.nil?

    parts = lines[(start + 1)...stop].filter_map do |line|
      value = presence(line[58..])
      next if value.nil?
      next if value.match?(/\A(?:BASIC PERMIT|TRADENAME|NO\.|4\. SERIAL|\(Required\))/i)
      next if value.match?(/\A(?:Domestic|Imported)\z/i)

      value
    end

    presence(parts.join(", "))
  end

  def class_type_from(text)
    presence(text[/CLASS\/TYPE DESCRIPTION\s+(.+?)(?:\n{2,}|AFFIX COMPLETE SET)/m, 1]&.lines&.first)
  end

  def container_embossed_info_from(text)
    raw = text[/15\. SHOW ANY INFORMATION.*?APPEARING ON LABELS\.\s*(.+?)\s+PART II/m, 1]
    presence(raw.to_s.squish)
  end

  def presence(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end

  class PdfCommandError < StandardError; end
end
