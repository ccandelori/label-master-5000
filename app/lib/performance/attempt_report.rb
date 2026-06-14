# frozen_string_literal: true

module Performance
  # Summarizes durable VerificationAttempt rows into the production view
  # operators need: queue wait, total/stage timing, verdict/error mix, and
  # cache/reuse split. It intentionally reads persisted attempts rather
  # than logs so reports survive worker restarts.
  class AttemptReport
    def initialize(scope:)
      @scope = scope
    end

    def to_h
      attempts = @scope.includes(:verification).order(:created_at).to_a
      {
        generated_at: Time.current.iso8601,
        attempts: attempts.size,
        states: attempts.group_by(&:state).transform_values(&:size),
        verdicts: verdict_counts(attempts),
        queue_wait_ms: distribution(attempts.filter_map(&:queue_wait_ms)),
        total_ms: distribution(stage_values(attempts, "total_ms")),
        stages: stage_distributions(attempts),
        extraction_reuse: extraction_reuse(attempts),
        errors: error_counts(attempts)
      }
    end

    private

    def verdict_counts(attempts)
      attempts.filter_map(&:verification)
              .group_by(&:overall_verdict)
              .transform_values(&:size)
    end

    def stage_distributions(attempts)
      stage_names = attempts.flat_map { |attempt| attempt.stage_timings.keys }.uniq.sort
      stage_names.to_h do |stage|
        [ stage, distribution(stage_values(attempts, stage)) ]
      end
    end

    def stage_values(attempts, stage)
      attempts.filter_map do |attempt|
        value = attempt.stage_timings[stage]
        value.is_a?(Numeric) ? value : nil
      end
    end

    def extraction_reuse(attempts)
      verifications = attempts.filter_map(&:verification)
      {
        reused: verifications.count(&:extraction_reused?),
        fresh: verifications.count { |verification| !verification.extraction_reused? },
        cold_like: verifications.count { |verification| !verification.extraction_reused? }
      }
    end

    def error_counts(attempts)
      error_attempts = attempts.select(&:error?)
      {
        total: error_attempts.size,
        by_class: error_attempts.group_by(&:error_class).transform_values(&:size)
      }
    end

    def distribution(values)
      sorted = values.compact.map(&:to_f).sort
      return { count: 0, min: nil, p50: nil, p95: nil, max: nil, avg: nil } if sorted.empty?

      {
        count: sorted.size,
        min: sorted.first.round(2),
        p50: percentile(sorted, 0.50),
        p95: percentile(sorted, 0.95),
        max: sorted.last.round(2),
        avg: (sorted.sum / sorted.size).round(2)
      }
    end

    def percentile(sorted, quantile)
      index = (sorted.size * quantile).ceil - 1
      sorted[index.clamp(0, sorted.size - 1)].round(2)
    end
  end
end
