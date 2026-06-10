# frozen_string_literal: true

# Creates hand-placed demo verifications for three seeded registry labels so
# the reviewer queue and review mode have annotated content without an
# ANTHROPIC_API_KEY. Bounding boxes were placed by eye against the artwork at
# natural resolution; real verifications get theirs from the vision model.
#
# Usage: bin/rails runner script/demo_review_data.rb
# (Idempotent: skips applications that already have a verification.)

DEMO_BOXES = {
  # Birch Lake bourbon wraparound, 1566x823.
  "26055001000716" => {
    brand: [ 600, 32, 332, 230 ],
    alcohol: [ 75, 600, 210, 26 ],
    net: [ 608, 718, 128, 34 ],
    warning: [ 50, 392, 262, 200 ]
  },
  # Stripper vodka, 840x660; the warning runs vertically up the right edge.
  "26110001000607" => {
    brand: [ 288, 29, 336, 79 ],
    alcohol: [ 495, 556, 162, 22 ],
    net: [ 543, 574, 62, 20 ],
    warning: [ 716, 392, 68, 268 ]
  },
  # Teddy Loves IPA, 1161x522; alcohol is the 7% roundel by the portrait.
  "26029001000269" => {
    brand: [ 452, 328, 250, 80 ],
    alcohol: [ 220, 165, 60, 60 ],
    net: [ 543, 460, 73, 26 ],
    warning: [ 7, 318, 198, 178 ]
  }
}.freeze

manifest = YAML.load_file(Rails.root.join("db/registry/manifest.yml"))
serial_to_ttbid = manifest["records"].to_h { |r| [ r["serial_number"] || r["ttbid"], r["ttbid"] ] }

batch = Batch.find_by!(name: "TTB registry sample")

DEMO_BOXES.each_with_index do |(ttbid, boxes), index|
  serial = serial_to_ttbid.key(ttbid)
  application = batch.label_applications.find_by!(serial_number: serial)

  if application.verifications.any?
    puts "#{application.brand_name}: verification already present - skipping"
    next
  end

  fail_case = index != 1
  field_checks = [
    { field: "brand_name", verdict: "pass", expected: application.brand_name,
      extracted: application.brand_name, citation: nil, note: nil },
    { field: "alcohol_content", verdict: "pass", expected: application.alcohol_content.to_s,
      extracted: "#{application.alcohol_content}% ALC/VOL", citation: nil, note: nil },
    { field: "net_contents", verdict: fail_case ? "needs_review" : "pass",
      expected: application.net_contents, extracted: application.net_contents,
      citation: fail_case ? "27 CFR 5.203" : nil,
      note: fail_case ? "Statement form needs a judgment call against the standard of fill." : nil },
    { field: "government_warning_prefix", verdict: fail_case ? "fail" : "pass",
      expected: "GOVERNMENT WARNING",
      extracted: fail_case ? "Government Warning" : "GOVERNMENT WARNING",
      citation: fail_case ? "27 CFR 16.22" : nil,
      note: fail_case ? "GOVERNMENT WARNING must appear in capital letters." : nil }
  ]

  extraction = { "fields" => {
    "brand_name" => { "text" => application.brand_name, "bbox" => boxes[:brand], "page" => 1 },
    "alcohol_statement" => { "text" => "#{application.alcohol_content}% ALC/VOL", "bbox" => boxes[:alcohol], "page" => 1 },
    "net_contents" => { "text" => application.net_contents, "bbox" => boxes[:net], "page" => 1 },
    "government_warning" => { "text" => "Government Warning: ...", "bbox" => boxes[:warning], "page" => 1 }
  } }

  application.verifications.create!(
    overall_verdict: fail_case ? "fail" : "pass",
    field_checks: field_checks,
    extraction: extraction,
    latency_ms: 4200,
    model_id: "demo-fixture"
  )
  puts "#{application.brand_name}: #{fail_case ? 'fail' : 'pass'} demo verification created"
end
