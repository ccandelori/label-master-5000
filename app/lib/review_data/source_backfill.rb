# frozen_string_literal: true

module ReviewData
  # Classifies existing records into durable provenance buckets and applies
  # reversible data-quality quarantine flags. This is intentionally a task
  # object rather than a migration so operators can dry-run and inspect the
  # exact affected records before persisting cleanup.
  class SourceBackfill
    MUTATION_BATCH = /\AMutations of /i
    MUTATION_SERIAL = /-MUT-/i
    REGISTRY_EVAL_BATCH = /\ATTB registry eval\b/i
    SEED_SAMPLE_BATCH = "TTB registry sample"
    DEMO_SERIAL = "DEMO-RETAKE"

    def initialize(io:, dry_run:)
      @io = io
      @dry_run = dry_run
    end

    def run
      batch_targets = target_batch_sources
      application_targets = target_application_sources(batch_targets)
      shared_checksums = shared_artwork_checksums(application_targets)

      batch_changes = apply_batch_sources(batch_targets)
      application_changes = apply_application_sources(application_targets, shared_checksums)
      report(batch_changes, application_changes)
      { batches: batch_changes, applications: application_changes }
    end

    private

    attr_reader :io, :dry_run

    def target_batch_sources
      Batch.order(:id).to_h { |batch| [ batch.id, classify_batch(batch) ] }
    end

    def classify_batch(batch)
      return "registry_eval" if batch.name.match?(REGISTRY_EVAL_BATCH)
      return "mutation" if batch.name.match?(MUTATION_BATCH)
      return "seed_sample" if batch.name == SEED_SAMPLE_BATCH

      batch.source_kind.presence || "batch_upload"
    end

    def target_application_sources(batch_targets)
      LabelApplication.includes(:batch).order(:id).index_with do |application|
        classify_application(application, batch_targets[application.batch_id])
      end
    end

    def classify_application(application, batch_source)
      return "demo" if application.serial_number == DEMO_SERIAL
      return "mutation" if application.serial_number.match?(MUTATION_SERIAL)
      return "mutation" if batch_source == "mutation"
      return "registry_eval" if batch_source == "registry_eval"
      return "seed_sample" if batch_source == "seed_sample"
      return "batch_upload" if batch_source == "batch_upload"

      application.source_kind.presence || "manual"
    end

    def shared_artwork_checksums(application_targets)
      ArtworkQuality.shared_checksums_for_targets(application_targets: application_targets)
    end

    def apply_batch_sources(batch_targets)
      batch_targets.filter_map do |batch_id, source_kind|
        batch = Batch.find(batch_id)
        next if batch.source_kind == source_kind

        previous_source_kind = batch.source_kind
        batch.update!(source_kind: source_kind) unless dry_run
        { id: batch.id, name: batch.name, from: previous_source_kind, to: source_kind }
      end
    end

    def apply_application_sources(application_targets, shared_checksums)
      application_targets.filter_map do |application, source_kind|
        reasons = quarantine_reasons(application, source_kind, shared_checksums)
        next if unchanged_application?(application, source_kind, reasons)

        previous_source_kind = application.source_kind
        apply_application_change(application, source_kind, reasons)
        {
          id: application.id,
          serial_number: application.serial_number,
          from: previous_source_kind,
          to: source_kind,
          quarantine_reasons: reasons
        }
      end
    end

    def unchanged_application?(application, source_kind, reasons)
      application.source_kind == source_kind &&
        application.quarantine_reasons.sort == reasons.sort &&
        quarantine_timestamp_correct?(application, reasons)
    end

    def quarantine_timestamp_correct?(application, reasons)
      reasons.any? ? application.quarantined_at.present? : application.quarantined_at.nil?
    end

    def apply_application_change(application, source_kind, reasons)
      return if dry_run

      application.source_kind = source_kind
      application.quarantine_reasons = reasons
      application.quarantined_at = reasons.any? ? (application.quarantined_at || Time.current) : nil
      application.save!
    end

    def quarantine_reasons(application, source_kind, shared_checksums)
      ArtworkQuality.reasons_for(application: application, source_kind: source_kind, shared_checksums: shared_checksums)
    end

    def report(batch_changes, application_changes)
      mode = dry_run ? "dry run" : "persisted"
      io.puts "review data source backfill #{mode}"
      io.puts "batch changes: #{batch_changes.size}"
      source_counts(batch_changes).each { |source_kind, count| io.puts "  #{source_kind}: #{count}" }
      io.puts "application changes: #{application_changes.size}"
      source_counts(application_changes).each { |source_kind, count| io.puts "  #{source_kind}: #{count}" }
      quarantine_counts(application_changes).each { |reason, count| io.puts "  quarantine #{reason}: #{count}" }
      application_changes.first(25).each do |change|
        io.puts "  #{change[:serial_number]}: #{change[:from]} -> #{change[:to]} #{change[:quarantine_reasons].join(', ')}"
      end
    end

    def source_counts(changes)
      changes.map { |change| change[:to] }.tally.sort.to_h
    end

    def quarantine_counts(changes)
      changes.flat_map { |change| change[:quarantine_reasons] }.tally.sort.to_h
    end
  end
end
