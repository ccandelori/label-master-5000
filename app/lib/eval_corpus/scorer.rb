# frozen_string_literal: true

module EvalCorpus
  # Read-only scoring over existing verifications: approved registry
  # labels measure the false-flag rate (they passed TTB review, so a
  # flag is presumptively ours to explain), mutants measure the catch
  # rate (each declares the field its verification must flag). Pure
  # functions over records the rake task assembles; no verification is
  # ever created here.
  module Scorer
    CLEAN_VERDICTS = %w[pass pass_with_note].freeze
    FLAGGED_VERDICTS = %w[needs_review fail].freeze

    # The registry never exposes declared net contents, so imports carry
    # a sentinel whose match check predictably asks for review; that one
    # check is excluded when scoring a sentinel-bearing positive.
    SENTINEL_NOTE = "Could not read a volume from the application value"

    MUTANT_SERIAL = /\A(?<parent>.+)-MUT-(?<type>[A-Z]+)\z/

    module_function

    def model_ids(applications)
      Verification.where(label_application: applications).distinct.pluck(:model_id).compact.sort
    end

    def mutants_for(parents)
      serials = parents.map(&:serial_number)
      LabelApplication
        .where("serial_number LIKE ?", "%-MUT-%")
        .select { |a| (m = a.serial_number.match(MUTANT_SERIAL)) && serials.include?(m[:parent]) }
    end

    # Deterministic stratified sample: limit parents allocated across
    # beverage types by largest remainder, serial order within a type.
    def stratified_sample(parents, limit)
      return parents.sort_by(&:serial_number) if limit.nil? || parents.size <= limit

      groups = parents.group_by(&:beverage_type).transform_values { |g| g.sort_by(&:serial_number) }
      exact = groups.transform_values { |g| g.size * limit / parents.size.to_f }
      counts = exact.transform_values(&:floor)
      exact.sort_by { |type, share| [ -(share - counts[type]), type ] }
           .first(limit - counts.values.sum)
           .each { |type, _| counts[type] += 1 }

      groups.flat_map { |type, g| g.first(counts[type]) }.sort_by(&:serial_number)
    end

    def score_model(parents:, mutants:, model_id:)
      {
        model_id: model_id,
        positives: score_positives(parents, model_id),
        negatives: score_negatives(mutants, model_id)
      }
    end

    def score_positives(parents, model_id)
      buckets = { clean: [], flagged: [], other: [], unverified: [] }
      parents.each do |application|
        verification = latest_verification(application, model_id)
        next buckets[:unverified] << application if verification.nil?

        checks = scoreable_checks(application, verification)
        verdict = effective_verdict(verification, checks)
        case verdict
        when *CLEAN_VERDICTS then buckets[:clean] << application
        when *FLAGGED_VERDICTS
          buckets[:flagged] << { application: application, checks: flagged_checks(checks) }
        else buckets[:other] << { application: application, verdict: verdict }
        end
      end
      buckets
    end

    def score_negatives(mutants, model_id)
      by_type = Hash.new { |h, k| h[k] = { caught: [], missed: [], unverified: [] } }
      mutants.each do |mutant|
        type = mutant.serial_number[MUTANT_SERIAL, :type]
        expected_field = Mutator::EXPECTED_FLAGS[type]
        next if expected_field.nil?

        verification = latest_verification(mutant, model_id)
        next by_type[type][:unverified] << mutant if verification.nil?

        expected_checks = verification.field_checks.select { |c| c.field == expected_field }
        if expected_checks.any? { |c| FLAGGED_VERDICTS.include?(c.verdict) }
          by_type[type][:caught] << mutant
        else
          by_type[type][:missed] << {
            application: mutant,
            actual: expected_checks.map { |c| "#{c.verdict}: #{c.note.to_s.first(60)}" }.presence || [ "no #{expected_field} check emitted" ]
          }
        end
      end
      by_type
    end

    def render(result, io:)
      model = result[:model_id]
      positives = result[:positives]
      verified = positives[:clean].size + positives[:flagged].size

      io.puts "== #{model}"
      io.puts "approved labels: #{positives[:clean].size} clean, #{positives[:flagged].size} flagged" \
              "#{positives[:other].any? ? ", #{positives[:other].size} other" : ""}" \
              ", #{positives[:unverified].size} unverified" \
              " - false-flag rate #{percent(positives[:flagged].size, verified)}"
      positives[:flagged].each do |entry|
        io.puts "  #{entry[:application].serial_number} (#{entry[:application].brand_name})"
        entry[:checks].first(3).each { |c| io.puts "    #{c.field} #{c.verdict}: #{c.note.to_s.first(60)}" }
      end
      positives[:other].each do |entry|
        io.puts "  #{entry[:application].serial_number}: #{entry[:verdict]}"
      end

      caught = missed = 0
      result[:negatives].sort.each do |type, bucket|
        caught += bucket[:caught].size
        missed += bucket[:missed].size
        io.puts "mutants #{type}: #{bucket[:caught].size} caught, #{bucket[:missed].size} missed, #{bucket[:unverified].size} unverified"
        bucket[:missed].each do |entry|
          io.puts "  MISSED #{entry[:application].serial_number}: #{entry[:actual].join(" | ")}"
        end
      end
      io.puts "overall catch rate: #{percent(caught, caught + missed)}"
      io.puts
    end

    def render_summary(results, io:)
      io.puts "== summary"
      io.puts format("%-28s %10s %12s %10s %8s", "model", "positives", "false-flag", "negatives", "catch")
      results.each do |result|
        positives = result[:positives]
        verified = positives[:clean].size + positives[:flagged].size
        caught = result[:negatives].values.sum { |b| b[:caught].size }
        missed = result[:negatives].values.sum { |b| b[:missed].size }
        io.puts format(
          "%-28s %10d %12s %10d %8s",
          result[:model_id], verified, percent(positives[:flagged].size, verified),
          caught + missed, percent(caught, caught + missed)
        )
      end
    end

    def latest_verification(application, model_id)
      application.verifications.where(model_id: model_id).order(created_at: :desc).first
    end

    # The sentinel's predictable review request is the importer's gap,
    # not the pipeline's finding; it is excluded only for the registry
    # positive itself (mutants declare concrete values where it matters).
    def scoreable_checks(application, verification)
      checks = verification.field_checks
      return checks unless application.net_contents == RegistryRecord::NET_CONTENTS_SENTINEL

      checks.reject { |c| c.field == "net_contents" && c.note == SENTINEL_NOTE }
    end

    def effective_verdict(verification, checks)
      return verification.overall_verdict if checks.empty?

      FieldCheck.overall(checks)
    end

    def flagged_checks(checks)
      checks.select { |c| FLAGGED_VERDICTS.include?(c.verdict) }
            .sort_by { |c| -FieldCheck::SEVERITY.fetch(c.verdict, 0) }
    end

    def percent(numerator, denominator)
      return "n/a" if denominator.zero?

      "#{(100.0 * numerator / denominator).round(1)}%"
    end
  end
end
