# frozen_string_literal: true

namespace :corpus do
  desc "Run deterministic review regression corpus"
  task run: :environment do
    result = ReviewCorpus::Runner.new(
      fixtures_dir: Rails.root.join("test/fixtures/review_corpus")
    ).run
    puts JSON.pretty_generate(result)
    abort "review corpus failed" if result.dig(:summary, :failed).positive?
  end
end
