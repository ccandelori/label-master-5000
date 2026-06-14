# frozen_string_literal: true

namespace :eval do
  desc "Import approved labels from TTB's public COLA Registry: bin/rails 'eval:import[20]' or 'eval:import[20,path/to/ttb_ids.txt]'"
  task :import, [ :count, :ids_file ] => :environment do |_t, args|
    client = EvalCorpus::RegistryClient.new(cache_dir: Rails.root.join("tmp/eval_cache"))
    EvalCorpus::Importer.new(client: client, io: $stdout).import(
      count: Integer(args[:count] || "20"),
      ids_file: args[:ids_file]
    )
  end

  desc "Repair clearly swapped front/back artwork slots: bin/rails 'eval:repair_artwork_roles[false]' to persist"
  task :repair_artwork_roles, [ :dry_run ] => :environment do |_t, args|
    dry_run = args[:dry_run].to_s != "false"
    repaired = EvalCorpus::ArtworkRoleRepairer.new(
      scope: LabelApplication.all,
      io: $stdout,
      dry_run: dry_run
    ).repair
    puts dry_run ? "dry run complete" : "repaired #{repaired} record(s)"
  end

  desc "Create known-bad mutated clones of one application: bin/rails 'eval:mutate[SERIAL]'"
  task :mutate, [ :serial ] => :environment do |_t, args|
    source = LabelApplication.find_by(serial_number: args[:serial])
    abort "no application with serial #{args[:serial].inspect}" if source.nil?

    EvalCorpus::Mutator.mutate(source, io: $stdout)
  end

  desc "Mutate every application in a batch: bin/rails 'eval:mutate_all[BATCH_ID]'"
  task :mutate_all, [ :batch_id ] => :environment do |_t, args|
    batch = Batch.find_by(id: args[:batch_id])
    abort "no batch ##{args[:batch_id]}" if batch.nil?

    batch.label_applications.find_each do |source|
      EvalCorpus::Mutator.mutate(source, io: $stdout)
    end
  end

  desc "Verify batch members + mutants lacking a result under the configured model: bin/rails 'eval:run[BATCH_ID]' or 'eval:run[BATCH_ID,40]'"
  task :run, [ :batch_id, :limit ] => :environment do |_t, args|
    batch = Batch.find_by(id: args[:batch_id])
    abort "no batch ##{args[:batch_id]}" if batch.nil?

    model_id = VerifyLabelJob.default_model_id
    limit = args[:limit].presence&.to_i
    parents = EvalCorpus::Scorer.stratified_sample(batch.label_applications.to_a, limit)
    mutants_by_parent = EvalCorpus::Scorer.mutants_for(parents).group_by do |m|
      m.serial_number[EvalCorpus::Scorer::MUTANT_SERIAL, :parent]
    end

    puts "verifying under #{model_id}: #{parents.size} parent(s) and their mutants"
    # Parents first: a mutant shares its parent's artwork fingerprint, so
    # its verification reuses the parent's fresh extraction (rules only).
    parents.each do |parent|
      [ parent, *mutants_by_parent.fetch(parent.serial_number, []) ].each do |application|
        if application.verifications.where(model_id: model_id).exists?
          puts "#{application.serial_number}: already verified under #{model_id}, skipping"
          next
        end

        started = Time.current
        begin
          verification = VerifyLabelJob.perform_now(application.id, nil, nil)
          puts "#{application.serial_number}: #{verification.overall_verdict} (#{(Time.current - started).round(1)}s)"
        rescue StandardError => e
          puts "#{application.serial_number}: ERROR #{e.class}: #{e.message.to_s.first(120)}"
        end
        $stdout.flush
      end
    end
  end

  desc "Score existing verifications: bin/rails 'eval:score[BATCH_ID]' or 'eval:score[BATCH_ID,model-id]'"
  task :score, [ :batch_id, :model_id ] => :environment do |_t, args|
    batch = Batch.find_by(id: args[:batch_id])
    abort "no batch ##{args[:batch_id]}" if batch.nil?

    parents = batch.label_applications.to_a
    mutants = EvalCorpus::Scorer.mutants_for(parents)
    model_ids = args[:model_id].presence&.then { |m| [ m ] } ||
                EvalCorpus::Scorer.model_ids(parents + mutants)
    abort "no verifications to score" if model_ids.empty?

    results = model_ids.map do |model_id|
      EvalCorpus::Scorer.score_model(parents: parents, mutants: mutants, model_id: model_id)
    end
    results.each { |r| EvalCorpus::Scorer.render(r, io: $stdout) }
    EvalCorpus::Scorer.render_summary(results, io: $stdout)
  end
end
