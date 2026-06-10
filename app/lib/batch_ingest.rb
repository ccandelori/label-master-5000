# frozen_string_literal: true

require "csv"

# Pure CSV-plus-images validation for batch uploads. Every problem is
# surfaced as a structured error before any record is created or any job
# enqueued - an importer's 300-row submission either starts cleanly or
# fails loudly with row numbers.
module BatchIngest
  REQUIRED_COLUMNS = %w[serial_number beverage_type brand_name applicant_name_address
                        net_contents image_filename].freeze

  OPTIONAL_COLUMNS = %w[imported fanciful_name alcohol_content country_of_origin
                        container_embossed_info varietals appellation vintage_year
                        declared_class_type actual_alcohol_content
                        contains_fd_c_yellow_5 contains_cochineal_carmine
                        contains_sulfites_10ppm contains_saccharin contains_aspartame
                        contains_added_coloring].freeze

  BEVERAGE_TYPES = %w[malt wine spirits].freeze

  Row = Data.define(:row_number, :attributes, :image_filename)
  RowError = Data.define(:row_number, :kind, :message)
  Result = Data.define(:rows, :errors) do
    def valid?
      errors.empty?
    end
  end

  module_function

  # csv_text: the raw CSV contents. image_filenames: names of the uploaded
  # files (duplicates preserved, so duplicate uploads are detectable).
  def parse(csv_text, image_filenames)
    errors = []
    errors.concat(duplicate_upload_errors(image_filenames))

    table = parse_csv(csv_text)
    if table.nil?
      errors << RowError.new(row_number: nil, kind: :malformed_csv, message: "The file could not be read as CSV")
      return Result.new(rows: [], errors: errors)
    end

    missing = REQUIRED_COLUMNS - table.headers.compact.map(&:strip)
    if missing.any?
      errors << RowError.new(row_number: nil, kind: :missing_columns,
                             message: "Missing required columns: #{missing.join(', ')}")
      return Result.new(rows: [], errors: errors)
    end

    unknown = table.headers.compact.map(&:strip) - REQUIRED_COLUMNS - OPTIONAL_COLUMNS
    if unknown.any?
      errors << RowError.new(row_number: nil, kind: :unknown_columns,
                             message: "Unknown columns: #{unknown.join(', ')}")
    end

    rows = []
    referenced = []
    table.each_with_index do |record, index|
      row_number = index + 2
      row_errors = validate_record(record, row_number, image_filenames)
      if row_errors.any?
        errors.concat(row_errors)
      else
        referenced << record["image_filename"].strip
        rows << build_row(record, row_number)
      end
    end

    orphans = image_filenames.uniq - referenced
    orphans.each do |name|
      errors << RowError.new(row_number: nil, kind: :orphan_image,
                             message: "Uploaded image #{name} is not referenced by any row")
    end

    Result.new(rows: rows, errors: errors)
  end

  def parse_csv(csv_text)
    CSV.parse(csv_text.to_s, headers: true)
  rescue CSV::MalformedCSVError
    nil
  end

  def duplicate_upload_errors(image_filenames)
    image_filenames.tally.select { |_, count| count > 1 }.keys.map do |name|
      RowError.new(row_number: nil, kind: :duplicate_image,
                   message: "Image #{name} was uploaded more than once")
    end
  end

  def validate_record(record, row_number, image_filenames)
    errors = []

    REQUIRED_COLUMNS.each do |column|
      if record[column].to_s.strip.empty?
        errors << RowError.new(row_number: row_number, kind: :missing_value,
                               message: "Row #{row_number}: #{column.humanize.downcase} is required")
      end
    end

    beverage_type = record["beverage_type"].to_s.strip.downcase
    if beverage_type.present? && !BEVERAGE_TYPES.include?(beverage_type)
      errors << RowError.new(row_number: row_number, kind: :invalid_value,
                             message: "Row #{row_number}: beverage_type must be malt, wine, or spirits")
    end

    %w[alcohol_content actual_alcohol_content].each do |column|
      value = record[column].to_s.strip
      if value.present? && Float(value, exception: false).nil?
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: #{column} must be a number")
      end
    end

    image = record["image_filename"].to_s.strip
    if image.present? && !image_filenames.include?(image)
      errors << RowError.new(row_number: row_number, kind: :missing_image,
                             message: "Row #{row_number}: no uploaded image named #{image}")
    end

    errors
  end

  def build_row(record, row_number)
    Row.new(
      row_number: row_number,
      image_filename: record["image_filename"].strip,
      attributes: {
        serial_number: record["serial_number"].strip,
        beverage_type: record["beverage_type"].strip.downcase,
        imported: cast_boolean(record["imported"]) || false,
        brand_name: record["brand_name"].strip,
        fanciful_name: presence(record["fanciful_name"]),
        applicant_name_address: record["applicant_name_address"].strip,
        alcohol_content: presence(record["alcohol_content"])&.to_f,
        net_contents: record["net_contents"].strip,
        country_of_origin: presence(record["country_of_origin"]),
        container_embossed_info: presence(record["container_embossed_info"]),
        varietals: split_varietals(record["varietals"]),
        appellation: presence(record["appellation"]),
        vintage_year: presence(record["vintage_year"])&.to_i,
        declared_class_type: presence(record["declared_class_type"]),
        actual_alcohol_content: presence(record["actual_alcohol_content"])&.to_f,
        contains_fd_c_yellow_5: cast_boolean(record["contains_fd_c_yellow_5"]),
        contains_cochineal_carmine: cast_boolean(record["contains_cochineal_carmine"]),
        contains_sulfites_10ppm: cast_boolean(record["contains_sulfites_10ppm"]),
        contains_saccharin: cast_boolean(record["contains_saccharin"]),
        contains_aspartame: cast_boolean(record["contains_aspartame"]),
        contains_added_coloring: cast_boolean(record["contains_added_coloring"])
      }
    )
  end

  def presence(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end

  # Tri-state: blank means unknown (nil), anything truthy/falsey casts.
  def cast_boolean(value)
    text = value.to_s.strip.downcase
    return nil if text.empty?

    %w[true yes 1 y].include?(text)
  end

  # Semicolons separate varietals inside a CSV cell.
  def split_varietals(value)
    value.to_s.split(";").map(&:strip).reject(&:empty?)
  end
end
