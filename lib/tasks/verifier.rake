# frozen_string_literal: true

namespace :verifier do
  desc "Print persisted verifier attempt metrics: bin/rails verifier:performance_report"
  task performance_report: :environment do
    puts JSON.pretty_generate(Performance::AttemptReport.new(scope: VerificationAttempt.all).to_h)
  end
end
