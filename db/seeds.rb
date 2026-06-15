# frozen_string_literal: true

# Demo data: 13 real approved labels from the TTB public COLA registry
# (db/registry/, fetched by script/harvest_cola_registry.rb) plus one
# deliberately degraded image for the request-retake flow.
#
# Seed data should be cheap and deterministic by default. Verification jobs
# only run when explicitly requested with RUN_SEED_VERIFICATIONS=true.

if Rails.root.join("downloads/ttb_cola_approved_applications_2026-06-13").exist?
  pdf_batch = Batch.seed_application_pdfs!
  puts "Seeded #{pdf_batch.label_applications.count} application PDF record(s)."
end

PRODUCT_TYPES = {
  "Wine" => "wine",
  "Distilled Spirits" => "spirits",
  "Malt Beverage" => "malt",
  "Malt" => "malt"
}.freeze

registry_dir = Rails.root.join("db/registry")
manifest = YAML.load_file(registry_dir.join("manifest.yml"))
values = YAML.load_file(registry_dir.join("application_values.yml"))

def registry_content_type(attachment)
  attachment["local_file"].to_s.end_with?(".png") ? "image/png" : "image/jpeg"
end

def attach_registry_artwork(application, name, registry_dir, attachment)
  image_path = registry_dir.join("images", attachment["local_file"])
  application.public_send(name).attach(
    io: File.open(image_path),
    filename: attachment["filename"],
    content_type: registry_content_type(attachment)
  )
end

def registry_front_attachment(record)
  EvalCorpus::ArtworkRoleResolver.pick_front_back(record["attachments"]).first
end

def registry_back_attachment(record)
  EvalCorpus::ArtworkRoleResolver.pick_front_back(record["attachments"]).last
end

def repair_seed_back_artwork(batch, manifest, registry_dir)
  repaired = 0
  manifest["records"].each do |record|
    back = registry_back_attachment(record)
    next if back.nil?

    application = batch.label_applications.find_by(serial_number: record["serial_number"] || record["ttbid"])
    next if application.nil? || application.back_artwork.attached?

    attach_registry_artwork(application, :back_artwork, registry_dir, back)
    application.save!
    repaired += 1
  end
  repaired
end

if Batch.exists?(name: "TTB registry sample")
  batch = Batch.find_by!(name: "TTB registry sample")
  batch.update!(source_kind: "seed_sample") unless batch.seed_sample?
  batch.label_applications.where(serial_number: "DEMO-RETAKE").update_all(source_kind: "demo")
  batch.label_applications.where.not(source_kind: "demo").update_all(source_kind: "seed_sample")
  repaired = repair_seed_back_artwork(batch, manifest, registry_dir)
  puts "Seed batch already present - repaired #{repaired} missing back artwork attachment(s)."
  return
end

batch = Batch.create!(name: "TTB registry sample", source_kind: "seed_sample", status: "processing",
                      total_rows: manifest["records"].size + 1)

manifest["records"].each_with_index do |record, index|
  transcribed = values.fetch(record["ttbid"], {})
  front = registry_front_attachment(record)
  back = registry_back_attachment(record)

  application = batch.label_applications.build(
    channel: "submitted",
    source_kind: "seed_sample",
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

  attach_registry_artwork(application, :artwork, registry_dir, front)
  attach_registry_artwork(application, :back_artwork, registry_dir, back) if back
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
    channel: "submitted",
    source_kind: "demo",
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

if ENV["RUN_SEED_VERIFICATIONS"] == "true"
  batch.verify_later(provider: nil, model: nil, mode: VerifyLabelJob::VERIFIER_V2_MODE)
  puts "Enqueued verification for #{batch.label_applications.count} labels."
else
  puts "RUN_SEED_VERIFICATIONS is not true - records created without running verification."
end
