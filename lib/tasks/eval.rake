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
end
