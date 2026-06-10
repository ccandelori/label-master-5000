# frozen_string_literal: true

# Demo data: 13 real approved labels from the TTB public COLA registry
# (db/registry/, fetched by script/harvest_cola_registry.rb) plus one
# deliberately degraded image for the request-retake flow.
#
# Verification jobs are enqueued only when an ANTHROPIC_API_KEY is present;
# without one, the records are created and any label can be checked later
# via "Edit and re-check".

PRODUCT_TYPES = {
  "Wine" => "wine",
  "Distilled Spirits" => "spirits",
  "Malt Beverage" => "malt",
  "Malt" => "malt"
}.freeze

registry_dir = Rails.root.join("db/registry")
manifest = YAML.load_file(registry_dir.join("manifest.yml"))
values = YAML.load_file(registry_dir.join("application_values.yml"))

if Batch.exists?(name: "TTB registry sample")
  puts "Seed batch already present - skipping (db:reset to rebuild)."
  return
end

batch = Batch.create!(name: "TTB registry sample", status: "processing",
                      total_rows: manifest["records"].size + 1)

manifest["records"].each_with_index do |record, index|
  transcribed = values.fetch(record["ttbid"], {})
  front = record["attachments"].find { |a| a["kind"].to_s.include?("Brand") } || record["attachments"].first

  application = batch.label_applications.build(
    row_number: index + 1,
    serial_number: record["serial_number"] || record["ttbid"],
    beverage_type: PRODUCT_TYPES.fetch(record["product_type"]),
    imported: record["source"] == "Imported",
    country_of_origin: record["source"] == "Imported" ? "See label" : nil,
    brand_name: record["brand_name"],
    fanciful_name: record["fanciful_name"],
    applicant_name_address: record["applicant_name_address"].to_s.sub(/,?\s*[^,]*\(Used on label\)/, ""),
    alcohol_content: transcribed["alcohol_content"],
    net_contents: transcribed["net_contents"] || "See label",
    container_embossed_info: record["container_embossed_info"],
    varietals: record["varietals"].to_s.split(/[;,]/).map(&:strip).reject(&:empty?),
    appellation: record["appellation"],
    vintage_year: transcribed["vintage_year"]
  )

  image_path = registry_dir.join("images", front["local_file"])
  content_type = front["local_file"].end_with?(".png") ? "image/png" : "image/jpeg"
  application.artwork.attach(io: File.open(image_path), filename: front["filename"], content_type: content_type)
  application.save!
  puts "Seeded #{record['brand_name']} (#{record['ttbid']})"
end

# Imported records: country of origin as read from the labels.
{
  "JOHNNIE WALKER" => "Scotland",
  "GUINNESS" => "Ireland",
  "MODELO ESPECIAL" => "Mexico",
  "STELLA ROSA" => "Spain",
  "BROUWERIJ 'TIJ" => "Netherlands"
}.each do |brand, country|
  batch.label_applications.find_by(brand_name: brand)&.update!(country_of_origin: country)
end

# A deliberately unreadable image for the request-retake demonstration.
degraded = registry_dir.join("images/bad_photo_demo.jpg")
if degraded.exist?
  application = batch.label_applications.create!(
    row_number: batch.total_rows,
    serial_number: "DEMO-RETAKE",
    beverage_type: "malt",
    brand_name: "Teddy Loves",
    applicant_name_address: "Fat Bottom Brewing, Nashville, TN",
    alcohol_content: 7.0,
    net_contents: "12 fl oz",
    artwork: { io: File.open(degraded), filename: "bad_photo_demo.jpg", content_type: "image/jpeg" }
  )
  puts "Seeded degraded-photo demo (#{application.serial_number})"
end

if ENV["ANTHROPIC_API_KEY"].present?
  batch.label_applications.find_each { |a| VerifyLabelJob.perform_later(a.id) }
  puts "Enqueued verification for #{batch.label_applications.count} labels."
else
  puts "No ANTHROPIC_API_KEY set - records created without running verification."
end
