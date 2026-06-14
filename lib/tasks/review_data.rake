# frozen_string_literal: true

namespace :review_data do
  desc "Classify source_kind and quarantine suspicious records: bin/rails 'review_data:backfill_sources[false]' to persist"
  task :backfill_sources, [ :dry_run ] => :environment do |_task, args|
    dry_run = args[:dry_run].to_s != "false"
    ReviewData::SourceBackfill.new(io: $stdout, dry_run: dry_run).run
    puts dry_run ? "dry run complete" : "backfill persisted"
  end
end
