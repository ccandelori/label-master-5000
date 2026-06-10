# frozen_string_literal: true

# Harvests real approved label records from the TTB public COLA registry
# (https://ttbonline.gov/colasonline/) into db/registry/: a manifest of the
# application data from each printable certificate plus the label artwork.
# These are public records; this script fetches a small, polite sample for
# use as calibration fixtures and demo seeds.
#
# Usage: ruby script/harvest_cola_registry.rb
#
# ttbonline.gov serves an incomplete TLS chain (the Entrust OV intermediate
# is missing). Verification stays ON: the intermediate is checked in at
# config/cola_registry_intermediate_ca.pem and added to the trust store.

require "net/http"
require "time"
require "openssl"
require "yaml"
require "fileutils"
require "cgi"

class RegistryClient
  HOST = "ttbonline.gov"

  def initialize
    @cookies = {}
  end

  def get(path)
    request(Net::HTTP::Get.new(path))
  end

  def post(path, params)
    req = Net::HTTP::Post.new(path)
    req.set_form_data(params)
    request(req)
  end

  def download(path)
    request(Net::HTTP::Get.new(path), binary: true)
  end

  private

  def trust_store
    @trust_store ||= OpenSSL::X509::Store.new.tap do |store|
      store.set_default_paths
      store.add_file(File.expand_path("../config/cola_registry_intermediate_ca.pem", __dir__))
    end
  end

  def request(req, binary: false)
    req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ") if @cookies.any?
    req["User-Agent"] = "label-verifier-fixture-harvest (research/prototype)"

    http = Net::HTTP.new(HOST, 443)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.cert_store = trust_store
    response = http.request(req)

    Array(response.get_fields("set-cookie")).each do |cookie|
      name, value = cookie.split(";").first.split("=", 2)
      @cookies[name] = value
    end

    sleep 1
    binary ? response.body : response.body.to_s
  end
end

module FormParser
  module_function

  def text_lines(html)
    text = html.gsub(%r{<script.*?</script>}m, " ").gsub(/<[^>]+>/, "\n")
    CGI.unescapeHTML(text).gsub(/&nbsp;?/, " ").lines.map(&:strip).reject(&:empty?)
  end

  def value_after(lines, anchor, skip_patterns)
    index = lines.index { |l| l.start_with?(anchor) }
    return nil if index.nil?

    lines[(index + 1)..(index + 3)].each do |candidate|
      next if skip_patterns.any? { |p| candidate.match?(p) }

      return candidate unless candidate.match?(/\A\d+[a-z]?\./)
    end
    nil
  end

  def applicant_block(lines)
    start = lines.index { |l| l.include?("IF USED ON LABEL") }
    finish = lines.index { |l| l.start_with?("4. SERIAL") }
    return nil if start.nil? || finish.nil?

    block = lines[(start + 1)...finish].reject { |l| l == "(Required)" }
    block.join(", ")
  end

  def embossed_info(lines)
    start = lines.index { |l| l.include?("APPEAR ON THE LABELS AFFIXED BELOW") }
    finish = lines.index { |l| l.start_with?("PART II") }
    return nil if start.nil? || finish.nil?

    value = lines[(start + 1)...finish].join(" ").strip
    value.empty? ? nil : value
  end

  def checked_boxes(html)
    html.scan(/<input[^>]*>/).filter_map do |input|
      next unless input.include?("checked")

      input[/alt="(?:Source of Product|Type of Product):\s*([^"]+)"/, 1]
    end
  end

  def attachments(html, lines)
    filenames = html.scan(/publicViewAttachment\.do\?filename=([^"&]+)&(?:amp;)?filetype=l/).flatten
    kinds = lines.each_cons(2).filter_map { |a, b| b if a == "Image Type:" }
    filenames.each_with_index.map do |filename, index|
      { "filename" => CGI.unescape(filename), "kind" => kinds[index] }
    end
  end

  def class_type_description(lines)
    index = lines.index("CLASS/TYPE DESCRIPTION")
    index ? lines[index + 1] : nil
  end

  def parse(html)
    lines = text_lines(html)
    checked = checked_boxes(html)

    {
      "serial_number" => value_after(lines, "4. SERIAL NUMBER", [ /\(Required\)/ ]),
      "brand_name" => value_after(lines, "6. BRAND NAME", [ /\(Required\)/ ]),
      "fanciful_name" => value_after(lines, "7. FANCIFUL NAME", [ /\(If any\)/ ]),
      "varietals" => normalize_na(value_after(lines, "10. GRAPE VARIETAL", [ /\(Wine Only\)/ ])),
      "appellation" => normalize_na(value_after(lines, "11. WINE APPELLATION", [ /\(If on label\)/ ])),
      "applicant_name_address" => applicant_block(lines),
      "container_embossed_info" => embossed_info(lines),
      "source" => checked.find { |c| %w[Domestic Imported].include?(c) },
      "product_type" => checked.find { |c| c.match?(/wine|distilled|malt/i) },
      "class_type_description" => class_type_description(lines),
      "date_issued" => value_after(lines, "19. DATE ISSUED", []),
      "attachments" => attachments(html, lines)
    }
  end

  def normalize_na(value)
    value == "N/A" ? nil : value
  end
end

class Harvester
  SEARCHES = [
    { product: "bourbon", want: 1 },
    { product: "vodka", want: 1 },
    { product: "ipa", want: 2 },
    { product: "lager", want: 1 },
    { product: "ale", want: 1 },
    { product: "barefoot", want: 1 },
    { product: "josh cellars", want: 1 },
    { product: "stella rosa", want: 1 },
    { product: "johnnie walker", want: 1 },
    { product: "guinness", want: 1 },
    { product: "modelo especial", want: 1 },
    { product: "casamigos", want: 1 }
  ].freeze

  DATE_FROM = "01/01/2026"
  DATE_TO = "06/01/2026"

  def initialize(output_dir)
    @client = RegistryClient.new
    @output_dir = output_dir
    FileUtils.mkdir_p(File.join(output_dir, "images"))
  end

  def run
    @client.get("/colasonline/publicSearchColasBasic.do")
    records = []

    SEARCHES.each do |search|
      ids = search_ids(search[:product]).first(search[:want])
      puts "#{search[:product]}: #{ids.join(', ')}"
      ids.each do |ttbid|
        next if records.any? { |r| r["ttbid"] == ttbid }

        record = harvest(ttbid)
        records << record if record
      end
    end

    manifest = { "harvested_at" => Time.now.utc.iso8601, "source" => "TTB public COLA registry", "records" => records }
    File.write(File.join(@output_dir, "manifest.yml"), manifest.to_yaml)
    puts "Wrote #{records.size} records to #{@output_dir}/manifest.yml"
  end

  private

  def search_ids(product)
    body = @client.post(
      "/colasonline/publicSearchColasBasicProcess.do?action=search",
      "searchCriteria.dateCompletedFrom" => DATE_FROM,
      "searchCriteria.dateCompletedTo" => DATE_TO,
      "searchCriteria.productOrFancifulName" => product,
      "searchCriteria.productNameSearchType" => "E"
    )
    body.scan(/ttbid=(\d{14})/).flatten.uniq
  end

  def harvest(ttbid)
    form_html = @client.get("/colasonline/viewColaDetails.do?action=publicFormDisplay&ttbid=#{ttbid}")
    record = FormParser.parse(form_html)
    return nil if record["brand_name"].nil?

    record["ttbid"] = ttbid
    record["attachments"].each_with_index do |attachment, index|
      data = @client.download("/colasonline/publicViewAttachment.do?filename=#{CGI.escape(attachment['filename'])}&filetype=l")
      extension = File.extname(attachment["filename"]).downcase
      extension = ".jpg" if extension.empty?
      local = "#{ttbid}_#{index}#{extension}"
      File.binwrite(File.join(@output_dir, "images", local), data)
      attachment["local_file"] = local
      attachment["bytes"] = data.bytesize
    end
    puts "  #{ttbid}: #{record['brand_name']} / #{record['class_type_description']} (#{record['attachments'].size} images)"
    record
  rescue StandardError => e
    warn "  #{ttbid}: skipped (#{e.class}: #{e.message})"
    nil
  end
end

Harvester.new(File.expand_path("../db/registry", __dir__)).run if $PROGRAM_NAME == __FILE__
