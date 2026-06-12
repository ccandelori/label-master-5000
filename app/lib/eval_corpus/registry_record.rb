# frozen_string_literal: true

module EvalCorpus
  # Pure parsing of the registry's printable TTB F 5100.31 form view (and
  # the detail view's two extra fields) into the attributes a
  # LabelApplication needs. No network, no persistence.
  module RegistryRecord
    # The registry never exposes net contents as data - it is only printed
    # on the label images - so imported records declare this sentinel. The
    # net-contents match check reports one predictable needs_review
    # ("Could not read a volume from the application value"); evaluation
    # scoring should exclude that check for registry imports.
    NET_CONTENTS_SENTINEL = "Not stated on application"

    PRODUCT_TYPES = {
      "Wine" => "wine",
      "Distilled Spirits" => "spirits",
      "Malt Beverage" => "malt"
    }.freeze

    Parsed = Data.define(
      :serial_number, :brand_name, :fanciful_name, :beverage_type, :imported,
      :applicant_name_address, :appellation, :varietals, :declared_class_type,
      :image_attachments
    )

    Attachment = Data.define(:path, :image_type)

    module_function

    # form view -> Parsed, or nil when the page is not a COLA (unknown ids
    # render an error page without the form's TTB ID field).
    def parse_form(html)
      doc = Nokogiri::HTML(html)
      return nil unless html.include?("AFFIX COMPLETE SET OF LABELS") || html.include?("PART I - APPLICATION")

      product = checked_alt(doc, "Type of Product")
      beverage_type = PRODUCT_TYPES[product]
      return nil if beverage_type.nil?

      Parsed.new(
        serial_number: field_after(doc, "4. SERIAL NUMBER"),
        brand_name: field_after(doc, "6. BRAND NAME"),
        fanciful_name: presence(field_after(doc, "7. FANCIFUL NAME")),
        beverage_type: beverage_type,
        imported: checked_alt(doc, "Source of Product") == "Imported",
        applicant_name_address: applicant_block(doc),
        appellation: presence(field_after(doc, "11. WINE APPELLATION")),
        varietals: varietals_list(doc),
        declared_class_type: class_type_description(doc),
        image_attachments: image_attachments(doc)
      )
    end

    # detail view -> { origin: ..., vintage: ... } (origin is a state name
    # for domestic products and a country for imports).
    def parse_detail(html)
      text = Nokogiri::HTML(html).text
      {
        origin: presence(labeled_value(text, "Origin Code:")),
        vintage: presence(labeled_value(text, "Wine Vintage:"))&.then { |v| v[/\d{4}/]&.to_i }
      }
    end

    def checked_alt(doc, prefix)
      node = doc.at_css(%(input[checked][alt^="#{prefix}: "])) ||
             doc.css("input[alt^=\"#{prefix}: \"]").find { |n| n.has_attribute?("checked") }
      node && node["alt"].delete_prefix("#{prefix}: ")
    end

    # Form values live in the innermost table cell that starts with their
    # label; outer cells contain whole nested tables, so the SHORTEST
    # matching cell is the value's own. Text past the next numbered label
    # is bleed from a sibling cell.
    def field_after(doc, label)
      cell = doc.css("td").select { |td| td.text.strip.start_with?(label) }.min_by { |td| td.text.length }
      return nil if cell.nil?

      value = cell.text.sub(label, "").gsub(/\s+/, " ").strip
      value = value.sub(/\A\((?:Required|If any|Wine Only|If on label)\)/, "").strip
      value = value.sub(/\s+\d{1,2}[a-z]?\.\s+[A-Z].*\z/, "").strip
      presence(value)
    end

    def applicant_block(doc)
      cell = doc.css("td").find { |td| td.text.include?("8. NAME AND ADDRESS OF APPLICANT") }
      return nil if cell.nil?

      lines = cell.css("td, div, p").map { |n| n.text.gsub(/\s+/, " ").strip } - [ "" ]
      lines = cell.text.split("\n").map { |l| l.gsub(/\s+/, " ").strip }.reject(&:empty?) if lines.empty?
      lines = lines.drop_while { |l| l.include?("NAME AND ADDRESS") || l.start_with?("(Required") }
      presence(lines.uniq.join(", "))
    end

    def varietals_list(doc)
      value = field_after(doc, "10. GRAPE VARIETAL(S)")
      return [] if value.nil? || value.casecmp("N/A").zero?

      value.split(",").map(&:strip).reject(&:empty?)
    end

    # The label section repeats "Image Type: <role>" before each image;
    # types and links pair up in document order.
    def image_attachments(doc)
      types = doc.text.scan(/Image Type:\s*([^\n]+?)\s*(?:Actual Dimensions|\n)/).flatten
                 .map { |t| t.gsub(/\s+/, " ").strip }
      paths = doc.css(%(a[href*="publicViewAttachment"], img[src*="publicViewAttachment"]))
                 .map { |node| node["href"] || node["src"] }.uniq
      paths.each_with_index.map { |path, index| Attachment.new(path: path, image_type: types[index]) }
    end

    # "CLASS/TYPE DESCRIPTION" sits in the TTB-use footer, label cell and
    # value cell side by side.
    def class_type_description(doc)
      cell = doc.css("td").select { |td| td.text.strip == "CLASS/TYPE DESCRIPTION" }.first
      value = cell&.parent&.text.to_s.sub("CLASS/TYPE DESCRIPTION", "")
      value = value.sub(/EXPIRATION DATE.*\z/m, "")
      presence(value.gsub(/\s+/, " ").strip) || presence(doc.text[/CLASS\/TYPE DESCRIPTION\s*\n\s*([^\n]+)/, 1])
    end

    # Detail-view values render on the line after their label.
    def labeled_value(text, label)
      tail = text[/#{Regexp.escape(label)}\s*\n?\s*([^\n]*(?:\n\s*[^\n]+)?)/, 1].to_s
      first = tail.lines.map { |l| l.gsub(/[[:space:] ]+/, " ").strip }.find { |l| !l.empty? }
      presence(first)
    end

    def presence(value)
      value.nil? || value.strip.empty? ? nil : value.strip
    end
  end
end
