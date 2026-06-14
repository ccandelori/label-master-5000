# frozen_string_literal: true

namespace :perf do
  desc "Verify real labels and persist stage timing JSON: bin/rails 'perf:verify_labels[batch_id,limit,mode]'"
  task :verify_labels, [ :batch_id, :limit, :mode ] => :environment do |_task, args|
    result = Performance::VerificationBenchmark.new(
      batch_id: args[:batch_id],
      limit: args[:limit],
      output_dir: Rails.root.join("tmp/perf"),
      mode: args[:mode].presence || "cached"
    ).run

    puts JSON.pretty_generate(result.slice(:artifact_path, :summary, :runtime_dependencies))
  end

  desc "Check OCR and image-processing runtime dependencies"
  task runtime_dependencies: :environment do
    report = Extraction::RuntimeDependencies.build.report
    puts JSON.pretty_generate(report)
    abort "runtime dependencies are missing" unless report[:ok]
  end

  desc "Stress PaddleOCR sidecar on real labels and persist timing JSON: bin/rails 'perf:ocr_sidecar[batch_id,limit]'"
  task :ocr_sidecar, [ :batch_id, :limit ] => :environment do |_task, args|
    result = Performance::OcrSidecarStress.new(
      batch_id: args[:batch_id],
      limit: args[:limit],
      output_dir: Rails.root.join("tmp/perf"),
      client: Extraction::PaddleOcrClient.build
    ).run

    puts JSON.pretty_generate(result.slice(:artifact_path, :summary, :runtime_dependencies))
  end
end
