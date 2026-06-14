# frozen_string_literal: true

require "cgi"
require "json"

# Adapter for the COLA sample export shape:
# applications.csv identifies applications by TTB id, while manifest.json
# lists one or more image files per id. The adapter translates that source
# format into the internal BatchIngest row contract.
module ColaSampleIngest
  REQUIRED_COLUMNS = %w[filename brand_name class_type bottler_address].freeze
  NET_CONTENTS_SENTINEL = "Not stated on application"
  IMAGE_EXTENSION_PATTERN = /\.(?:jpe?g|png|webp|pdf)\z/i
  MANIFEST_RESULT = Data.define(:images_by_serial, :errors)

  module_function

  def csv?(table)
    headers = normalized_headers(table)
    headers.include?("filename") && (headers & REQUIRED_COLUMNS).size >= 2
  end

  def parse(table:, image_filenames:, manifest_text:)
    missing = REQUIRED_COLUMNS - normalized_headers(table)
    if missing.any?
      return BatchIngest::Result.new(
        rows: [],
        errors: [
          BatchIngest::RowError.new(
            row_number: nil,
            kind: :missing_columns,
            message: "Missing required COLA sample columns: #{missing.join(', ')}"
          )
        ]
      )
    end

    manifest = parse_manifest(manifest_text)
    return BatchIngest::Result.new(rows: [], errors: manifest.errors) if manifest.errors.any?

    rows = []
    errors = []
    referenced = []

    table.each_with_index do |record, index|
      row_number = index + 2
      row_errors = validate_record(record, row_number)
      row_errors.concat(validate_images(record, row_number, image_filenames, manifest.images_by_serial))

      if row_errors.any?
        errors.concat(row_errors)
      else
        row = build_row(record, row_number, image_filenames, manifest.images_by_serial)
        referenced.concat(row.referenced_image_filenames)
        rows << row
      end
    end

    errors.concat(orphan_upload_errors(image_filenames, referenced))

    BatchIngest::Result.new(rows: rows, errors: errors)
  end

  def normalized_headers(table)
    table.headers.compact.map { |header| header.to_s.strip }
  end

  def parse_manifest(manifest_text)
    text = manifest_text.to_s.strip
    return MANIFEST_RESULT.new(images_by_serial: nil, errors: []) if text.empty?

    payload = JSON.parse(text)
    unless payload.is_a?(Array)
      return MANIFEST_RESULT.new(
        images_by_serial: {},
        errors: [
          BatchIngest::RowError.new(
            row_number: nil,
            kind: :malformed_manifest,
            message: "Manifest JSON must be an array of COLA records"
          )
        ]
      )
    end

    MANIFEST_RESULT.new(images_by_serial: manifest_images_by_serial(payload), errors: [])
  rescue JSON::ParserError
    MANIFEST_RESULT.new(
      images_by_serial: {},
      errors: [
        BatchIngest::RowError.new(
          row_number: nil,
          kind: :malformed_manifest,
          message: "The manifest file could not be read as JSON"
        )
      ]
    )
  end

  def manifest_images_by_serial(records)
    records.each_with_object({}) do |record, images_by_serial|
      next unless record.is_a?(Hash)

      serial = presence(record["ttbId"])
      next if serial.nil?

      images_by_serial[serial] = Array(record["images"]).map { |image| presence(image) }.compact
    end
  end

  def validate_record(record, row_number)
    errors = []

    REQUIRED_COLUMNS.each do |column|
      if record[column].to_s.strip.empty?
        errors << BatchIngest::RowError.new(
          row_number: row_number,
          kind: :missing_value,
          message: "Row #{row_number}: #{column.humanize.downcase} is required"
        )
      end
    end

    if beverage_type_for(record).nil?
      errors << BatchIngest::RowError.new(
        row_number: row_number,
        kind: :invalid_value,
        message: "Row #{row_number}: class_type could not be mapped to malt, wine, or spirits"
      )
    end

    alcohol_content = record["alcohol_content"].to_s.strip
    if alcohol_content.present? && Float(alcohol_content, exception: false).nil?
      errors << BatchIngest::RowError.new(
        row_number: row_number,
        kind: :invalid_value,
        message: "Row #{row_number}: alcohol_content must be a number"
      )
    end

    errors
  end

  def validate_images(record, row_number, image_filenames, manifest_images_by_serial)
    serial = record["filename"].to_s.strip
    images = image_filenames_for(serial, image_filenames, manifest_images_by_serial)
    return missing_image_errors(row_number, serial) if images.empty?

    images.filter_map do |image|
      next if image_filenames.include?(image)

      BatchIngest::RowError.new(
        row_number: row_number,
        kind: :missing_image,
        message: "Row #{row_number}: no uploaded image named #{image}"
      )
    end
  end

  def missing_image_errors(row_number, serial)
    [
      BatchIngest::RowError.new(
        row_number: row_number,
        kind: :missing_image,
        message: "Row #{row_number}: no uploaded image found for COLA sample #{serial}"
      )
    ]
  end

  def build_row(record, row_number, image_filenames, manifest_images_by_serial)
    images = image_filenames_for(record["filename"].to_s.strip, image_filenames, manifest_images_by_serial)

    BatchIngest::Row.new(
      row_number: row_number,
      image_filename: images.first,
      back_image_filename: images.second,
      auxiliary_image_filenames: images.drop(2),
      attributes: attributes_for(record)
    )
  end

  def attributes_for(record)
    country = country_of_origin_for(record)
    {
      serial_number: record["filename"].to_s.strip,
      beverage_type: beverage_type_for(record),
      imported: country.present?,
      brand_name: record["brand_name"].to_s.strip,
      fanciful_name: presence(record["fanciful_name"]),
      applicant_name_address: CGI.unescapeHTML(record["bottler_address"].to_s.strip),
      alcohol_content: presence(record["alcohol_content"])&.to_f,
      net_contents: presence(record["net_contents"]) || NET_CONTENTS_SENTINEL,
      country_of_origin: country,
      container_embossed_info: nil,
      varietals: [],
      appellation: nil,
      vintage_year: nil,
      declared_class_type: presence(record["class_type"]),
      actual_alcohol_content: nil,
      contains_fd_c_yellow_5: nil,
      contains_cochineal_carmine: nil,
      contains_sulfites_10ppm: nil,
      contains_saccharin: nil,
      contains_aspartame: nil,
      contains_added_coloring: nil
    }
  end

  def beverage_type_for(record)
    class_type = record["class_type"].to_s.upcase
    return "malt" if class_type.match?(/\b(MALT|BEER|ALE|LAGER|PORTER|STOUT|IPA)\b/)
    return "wine" if class_type.match?(/\b(WINE|SAKE|MEAD|CHAMPAGNE|SHERRY|PORT)\b/)

    spirits_pattern = /\b(VODKA|WHISKEY|WHISKY|BOURBON|RUM|GIN|TEQUILA|CURACAO|COCKTAILS?|LIQUEURS?|CORDIALS?|BRANDY|DISTILLED|SPIRITS?)\b/
    return "spirits" if class_type.match?(spirits_pattern) || class_type.include?("PROPRIETAR")

    nil
  end

  def country_of_origin_for(record)
    country = presence(record["country_of_origin"])
    return nil if country.nil?

    country.sub(/\Aproduct\s+of\s+/i, "").strip
  end

  def image_filenames_for(serial, image_filenames, manifest_images_by_serial)
    return manifest_images_by_serial.fetch(serial, []) if manifest_images_by_serial

    image_filenames
      .select { |filename| filename.match?(/\A#{Regexp.escape(serial)}-\d+#{IMAGE_EXTENSION_PATTERN}/) }
      .sort_by { |filename| image_sequence(filename) }
  end

  def image_sequence(filename)
    filename[/-(\d+)#{IMAGE_EXTENSION_PATTERN}/, 1].to_i
  end

  def orphan_upload_errors(image_filenames, referenced)
    orphans = image_filenames.uniq - referenced
    orphans.map do |name|
      BatchIngest::RowError.new(
        row_number: nil,
        kind: :orphan_image,
        message: "Uploaded image #{name} is not referenced by any row"
      )
    end
  end

  def presence(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end
end
