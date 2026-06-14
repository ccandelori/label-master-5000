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
                        back_image_filename
                        container_embossed_info varietals appellation vintage_year
                        declared_class_type actual_alcohol_content
                        contains_fd_c_yellow_5 contains_cochineal_carmine
                        contains_sulfites_10ppm contains_saccharin contains_aspartame
                        contains_added_coloring].freeze

  BEVERAGE_TYPES = %w[malt wine spirits].freeze
  BOOLEAN_COLUMNS = %w[imported contains_fd_c_yellow_5 contains_cochineal_carmine
                       contains_sulfites_10ppm contains_saccharin contains_aspartame
                       contains_added_coloring].freeze
  NUMERIC_PERCENT_COLUMNS = %w[alcohol_content actual_alcohol_content].freeze
  TRUTHY_VALUES = %w[true yes 1 y].freeze
  FALSEY_VALUES = %w[false no 0 n].freeze
  BOOLEAN_VALUES = (TRUTHY_VALUES + FALSEY_VALUES).freeze

  Row = Data.define(:row_number, :attributes, :image_filename, :back_image_filename, :auxiliary_image_filenames) do
    def referenced_image_filenames
      [ image_filename, back_image_filename, *auxiliary_image_filenames ].compact
    end
  end
  RowError = Data.define(:row_number, :kind, :message)
  Result = Data.define(:rows, :errors) do
    def valid?
      errors.empty?
    end
  end

  module_function

  # csv_text: the raw CSV contents. image_filenames: names of the uploaded
  # files (duplicates preserved, so duplicate uploads are detectable).
  def parse(csv_text, image_filenames, manifest_text: nil)
    errors = []
    errors.concat(duplicate_upload_errors(image_filenames))

    table = parse_csv(csv_text)
    if table.nil?
      errors << RowError.new(row_number: nil, kind: :malformed_csv, message: "The file could not be read as CSV")
      return Result.new(rows: [], errors: errors)
    end

    if ColaSampleIngest.csv?(table)
      result = ColaSampleIngest.parse(table: table, image_filenames: image_filenames, manifest_text: manifest_text)
      return Result.new(rows: result.rows, errors: errors + result.errors)
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
    references_by_name = Hash.new { |hash, name| hash[name] = [] }
    table.each_with_index do |record, index|
      row_number = index + 2
      referenced_image_filenames_for(record).each { |name| references_by_name[name] << row_number }
      row_errors = validate_record(record, row_number, image_filenames)
      if row_errors.any?
        errors.concat(row_errors)
      else
        row = build_row(record, row_number)
        rows << row
      end
    end

    errors.concat(duplicate_reference_errors(references_by_name))

    orphans = image_filenames.uniq - references_by_name.keys
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

    NUMERIC_PERCENT_COLUMNS.each do |column|
      value = record[column].to_s.strip
      next if value.empty?

      number = Float(value, exception: false)
      if number.nil?
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: #{column} must be a number")
      elsif number.negative? || number >= 100
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: #{column} must be at least 0 and less than 100")
      end
    end

    BOOLEAN_COLUMNS.each do |column|
      value = record[column].to_s.strip.downcase
      if value.present? && !BOOLEAN_VALUES.include?(value)
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: #{column} must be true, false, yes, no, 1, or 0")
      end
    end

    vintage = record["vintage_year"].to_s.strip
    if vintage.present?
      year = Integer(vintage, exception: false)
      if year.nil? || !vintage.match?(/\A\d{4}\z/)
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: vintage_year must be a four-digit year")
      elsif year <= 1900 || year > 2100
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: vintage_year must be between 1901 and 2100")
      end
    end

    if cast_boolean(record["imported"]) == true && record["country_of_origin"].to_s.strip.empty?
      errors << RowError.new(row_number: row_number, kind: :missing_value,
                             message: "Row #{row_number}: country_of_origin is required when imported is true")
    end

    image = record["image_filename"].to_s.strip
    back_image = record["back_image_filename"].to_s.strip
    errors.concat(validate_image_reference(record, row_number, "image_filename", image_filenames))
    errors.concat(validate_image_reference(record, row_number, "back_image_filename", image_filenames))

    if image.present? && back_image.present?
      if image == back_image
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: back_image_filename must be different from image_filename")
      elsif pdf_filename?(image)
        errors << RowError.new(row_number: row_number, kind: :invalid_value,
                               message: "Row #{row_number}: back_image_filename cannot accompany PDF artwork")
      end
    end

    errors
  end

  def validate_image_reference(record, row_number, column, image_filenames)
    image = record[column].to_s.strip
    return [] if image.empty?
    return [] if image_filenames.include?(image)

    [ RowError.new(row_number: row_number, kind: :missing_image,
                   message: "Row #{row_number}: no uploaded image named #{image} for #{column}") ]
  end

  def referenced_image_filenames_for(record)
    %w[image_filename back_image_filename].filter_map { |column| presence(record[column]) }
  end

  def duplicate_reference_errors(references_by_name)
    references_by_name.filter_map do |name, row_numbers|
      rows = row_numbers.uniq
      next nil if rows.one?

      RowError.new(row_number: nil, kind: :duplicate_image_reference,
                   message: "Image #{name} is referenced by multiple rows: #{rows.join(', ')}")
    end
  end

  def build_row(record, row_number)
    Row.new(
      row_number: row_number,
      image_filename: record["image_filename"].strip,
      back_image_filename: presence(record["back_image_filename"]),
      auxiliary_image_filenames: [],
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
    return true if TRUTHY_VALUES.include?(text)
    return false if FALSEY_VALUES.include?(text)

    nil
  end

  # Semicolons separate varietals inside a CSV cell.
  def split_varietals(value)
    value.to_s.split(";").map(&:strip).reject(&:empty?)
  end

  def pdf_filename?(filename)
    File.extname(filename).casecmp(".pdf").zero?
  end
end
