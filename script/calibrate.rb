# frozen_string_literal: true

# Live calibration: runs real extraction + rules over the seeded TTB
# registry sample and reports per-record verdicts. These labels were all
# approved by TTB, so they should overwhelmingly pass; failures are either
# engine bugs, transcription gaps, or documented BAM-vs-current-regulation
# divergences (which arrive as needs_review with a citation).
#
# Usage: ANTHROPIC_API_KEY=... bin/rails runner script/calibrate.rb
# Cost: one vision call per record (extraction reuse covers re-runs).

abort "ANTHROPIC_API_KEY is required for live calibration" if ENV["ANTHROPIC_API_KEY"].blank?

batch = Batch.find_by!(name: "TTB registry sample")
puts "Calibrating against #{batch.label_applications.count} registry records...\n\n"

results = batch.label_applications.order(:row_number).map do |application|
  verification = VerifyLabelJob.perform_now(application.id)
  flagged = verification.field_checks.select { |c| %w[fail needs_review].include?(c.verdict) }
  puts format("%-18s %-14s %s", application.brand_name.to_s[0, 17], verification.overall_verdict,
              flagged.map { |c| "#{c.field}(#{c.verdict})" }.join(", "))
  flagged.each { |c| puts "    #{c.field}: #{c.note} [#{c.citation}]" }
  verification
rescue Extraction::ExtractionError => e
  puts format("%-18s %-14s %s", application.brand_name.to_s[0, 17], "error", e.message[0, 60])
  nil
end

completed = results.compact
verdicts = completed.group_by(&:overall_verdict).transform_values(&:size)
latencies = completed.filter_map(&:latency_ms).sort

puts "\nVerdicts: #{verdicts.inspect}"
if latencies.any?
  puts "Latency: avg #{(latencies.sum / latencies.size / 1000.0).round(1)}s, " \
       "p95 #{(latencies[(latencies.size * 0.95).ceil - 1] / 1000.0).round(1)}s"
end
