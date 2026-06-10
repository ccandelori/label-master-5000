# frozen_string_literal: true

# Creates hand-built demo verifications for three seeded registry labels so
# the reviewer queue and review mode have annotated content without an
# ANTHROPIC_API_KEY. In real operation both the verdicts and the bounding
# boxes come from the pipeline (vision extraction + rules engine); here the
# boxes were placed by eye against the artwork at natural resolution and the
# verdicts reflect what is actually on each label - these are all approved
# TTB labels, so they pass, with one honest judgment call on the Stripper
# side panel. For real findings, set ANTHROPIC_API_KEY and re-run the seeds
# (Modelo Especial's metric-only net contents genuinely fires, for example).
#
# Usage: bin/rails runner script/demo_review_data.rb
# (Idempotent: skips applications that already have a verification.)

DEMO_RECORDS = {
  # Boxes are in the extraction pipeline's normalized 0-1000 coordinate
  # space (fractions of image width/height), placed by eye per label.
  # Birch Lake bourbon wraparound. Clean label: caps-and-bold warning,
  # metric standard of fill, conforming alcohol statement.
  "26055001000716" => {
    overall: "pass",
    boxes: {
      brand: [ 383, 39, 212, 279 ],
      alcohol: [ 48, 729, 134, 32 ],
      net: [ 388, 872, 82, 41 ],
      warning: [ 32, 476, 167, 243 ]
    },
    checks: {
      net_verdict: "pass", net_note: nil, net_citation: nil,
      warning_verdict: "pass", warning_note: nil, warning_citation: nil
    }
  },
  # Stripper vodka; the warning runs vertically up the right edge.
  # The caps prefix is present, but bold weight is genuinely hard to judge
  # on the rotated side panel - a real judgment call for the reviewer.
  "26110001000607" => {
    overall: "needs_review",
    boxes: {
      brand: [ 343, 44, 400, 120 ],
      alcohol: [ 589, 842, 193, 33 ],
      net: [ 646, 870, 74, 30 ],
      warning: [ 852, 594, 81, 406 ]
    },
    checks: {
      net_verdict: "pass", net_note: nil, net_citation: nil,
      warning_verdict: "needs_review",
      warning_note: "The GOVERNMENT WARNING prefix must be in bold type; weight is hard to judge on the rotated side panel - verify against the artwork.",
      warning_citation: "27 CFR 16.22"
    }
  },
  # Teddy Loves IPA. Clean label; alcohol is the 7% roundel.
  "26029001000269" => {
    overall: "pass",
    boxes: {
      brand: [ 389, 628, 215, 153 ],
      alcohol: [ 319, 456, 47, 105 ],
      net: [ 469, 954, 62, 38 ],
      warning: [ 6, 609, 171, 341 ]
    },
    checks: {
      net_verdict: "pass", net_note: nil, net_citation: nil,
      warning_verdict: "pass", warning_note: nil, warning_citation: nil
    }
  }
}.freeze

manifest = YAML.load_file(Rails.root.join("db/registry/manifest.yml"))
serial_to_ttbid = manifest["records"].to_h { |r| [ r["serial_number"] || r["ttbid"], r["ttbid"] ] }

batch = Batch.find_by!(name: "TTB registry sample")

DEMO_RECORDS.each do |ttbid, record|
  serial = serial_to_ttbid.key(ttbid)
  application = batch.label_applications.find_by!(serial_number: serial)

  if application.verifications.any?
    puts "#{application.brand_name}: verification already present - skipping"
    next
  end

  checks = record[:checks]
  field_checks = [
    { field: "brand_name", verdict: "pass", expected: application.brand_name,
      extracted: application.brand_name, citation: nil, note: nil },
    { field: "alcohol_content", verdict: "pass", expected: application.alcohol_content.to_s,
      extracted: "#{application.alcohol_content}% ALC/VOL", citation: nil, note: nil },
    { field: "net_contents", verdict: checks[:net_verdict], expected: application.net_contents,
      extracted: application.net_contents, citation: checks[:net_citation], note: checks[:net_note] },
    { field: "government_warning_bold", verdict: checks[:warning_verdict], expected: "GOVERNMENT WARNING in bold",
      extracted: "GOVERNMENT WARNING", citation: checks[:warning_citation], note: checks[:warning_note] }
  ]

  boxes = record[:boxes]
  extraction = { "fields" => {
    "brand_name" => { "text" => application.brand_name, "bbox" => boxes[:brand], "page" => 1 },
    "alcohol_statement" => { "text" => "#{application.alcohol_content}% ALC/VOL", "bbox" => boxes[:alcohol], "page" => 1 },
    "net_contents" => { "text" => application.net_contents, "bbox" => boxes[:net], "page" => 1 },
    "government_warning" => { "text" => "GOVERNMENT WARNING: ...", "bbox" => boxes[:warning], "page" => 1 }
  } }

  application.verifications.create!(
    overall_verdict: record[:overall],
    field_checks: field_checks,
    extraction: extraction,
    latency_ms: 4200,
    model_id: "demo-fixture"
  )
  puts "#{application.brand_name}: #{record[:overall]} demo verification created"
end
