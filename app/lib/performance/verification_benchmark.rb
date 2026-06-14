# frozen_string_literal: true

require "fileutils"

module Performance
  # Runs real label applications through VerifyLabelJob and persists a
  # stage-level timing artifact for comparing optimization experiments.
  class VerificationBenchmark
    EVENT_PATTERN = /\Averification\.stage\.label_verifier\z/
    MODES = %w[cold cached vlm legacy_vision].freeze

    def initialize(batch_id:, limit:, output_dir:, mode:)
      @batch_id = batch_id
      @limit = parsed_limit(limit)
      @output_dir = Pathname(output_dir)
      @mode = parsed_mode(mode)
    end

    def run
      selected = applications.to_a
      events = []
      records = []
      started_wall = Time.current
      started = monotonic_ms

      with_mode_settings do
        ActiveSupport::Notifications.subscribed(subscriber(events), EVENT_PATTERN) do
          selected.each do |application|
            records << measure_application(application)
          end
        end
      end

      completed_wall = Time.current
      total_duration_ms = monotonic_ms - started
      artifact = artifact_for(started_wall)
      payload = payload_for(
        applications: selected,
        records: records,
        events: events,
        total_duration_ms: total_duration_ms,
        started_at: started_wall,
        completed_at: completed_wall,
        artifact: artifact
      )
      persist(artifact, payload)
      payload
    end

    private

    def applications
      scope = @batch_id.to_s.strip.empty? ? LabelApplication.all : Batch.find(@batch_id).label_applications
      scope = scope.joins(:artwork_attachment).order(:id)
      @limit ? scope.limit(@limit) : scope
    end

    def parsed_limit(limit)
      text = limit.to_s.strip
      return nil if text.empty?

      value = Integer(text, exception: false)
      raise ArgumentError, "limit must be a positive integer" if value.nil? || value <= 0

      value
    end

    def parsed_mode(mode)
      text = mode.to_s.strip
      raise ArgumentError, "mode must be one of: #{MODES.join(', ')}" unless MODES.include?(text)

      text
    end

    def subscriber(events)
      lambda do |name, started, finished, _id, payload|
        events << payload.merge(
          event: name,
          duration_ms: ((finished - started) * 1000.0).round(2)
        )
      end
    end

    def measure_application(application)
      started = monotonic_ms
      verification = VerifyLabelJob.perform_now(application.id)
      {
        label_application_id: application.id,
        serial_number: application.serial_number,
        brand_name: application.brand_name,
        verification_id: verification.id,
        overall_verdict: verification.overall_verdict,
        extraction_reused: verification.extraction_reused,
        ok: true,
        duration_ms: monotonic_ms - started
      }
    rescue StandardError => e
      {
        label_application_id: application.id,
        serial_number: application.serial_number,
        brand_name: application.brand_name,
        ok: false,
        error_class: e.class.name,
        error_message: e.message.to_s.first(500),
        duration_ms: monotonic_ms - started
      }
    end

    def payload_for(applications:, records:, events:, total_duration_ms:, started_at:, completed_at:, artifact:)
      {
        run_id: artifact.basename(".json").to_s,
        started_at: started_at.iso8601,
        completed_at: completed_at.iso8601,
        artifact_path: artifact.to_s,
        scope: {
          batch_id: @batch_id.presence,
          limit: @limit,
          label_application_ids: applications.map(&:id),
          mode: @mode,
          extraction_reuse_enabled: extraction_reuse_enabled?
        },
        environment: environment_payload,
        runtime_dependencies: Extraction::RuntimeDependencies.build.report,
        records: records,
        events: events,
        summary: summary(records, events, total_duration_ms)
      }
    end

    def environment_payload
      config = Rails.application.config.x.extraction
      {
        rails_env: Rails.env,
        ruby_engine: RUBY_ENGINE,
        ruby_version: RUBY_VERSION,
        extraction_provider: config.provider,
        extraction_model: config.model,
        extraction_mode: config.mode,
        ocr_engine: config.ocr_engine,
        paddle_url: config.paddle_url,
        verify_concurrency: ENV.fetch("VERIFY_CONCURRENCY", nil),
        benchmark_mode: @mode
      }
    end

    def summary(records, events, total_duration_ms)
      successes = records.count { |record| record[:ok] }
      failures = records.size - successes
      record_duration = distribution(records.map { |record| record[:duration_ms] })
      {
        labels: records.size,
        successes: successes,
        failures: failures,
        total_duration_ms: total_duration_ms,
        labels_per_second: per_second(records.size, total_duration_ms),
        record_duration_ms: record_duration,
        stages: stage_distributions(events),
        extraction_reuse: extraction_reuse_summary(records),
        performance_target: performance_target(record_duration)
      }
    end

    def stage_distributions(events)
      stage_events = events.select { |event| event[:event] == "verification.stage.label_verifier" }
      stage_events.group_by { |event| event[:stage].to_s }.transform_values do |items|
        distribution(items.map { |event| event[:duration_ms] })
      end
    end

    def extraction_reuse_summary(records)
      {
        reused: records.count { |record| record[:ok] && record[:extraction_reused] },
        fresh: records.count { |record| record[:ok] && !record[:extraction_reused] }
      }
    end

    def performance_target(record_duration)
      target_ms = 5000
      {
        cold_label_p50_ms: target_ms,
        applies: @mode == "cold",
        p50_met: @mode == "cold" && !record_duration[:p50].nil? ? record_duration[:p50] <= target_ms : nil,
        p95_ms: record_duration[:p95],
        max_ms: record_duration[:max]
      }
    end

    def distribution(values)
      clean = values.compact.map(&:to_f).sort
      return { count: 0, min: nil, p50: nil, p95: nil, max: nil, avg: nil } if clean.empty?

      {
        count: clean.size,
        min: clean.first.round(2),
        p50: percentile(clean, 0.50),
        p95: percentile(clean, 0.95),
        max: clean.last.round(2),
        avg: (clean.sum / clean.size).round(2)
      }
    end

    def percentile(sorted, quantile)
      index = (sorted.size * quantile).ceil - 1
      sorted[index.clamp(0, sorted.size - 1)].round(2)
    end

    def per_second(count, duration_ms)
      return nil if duration_ms.zero?

      (count * 1000.0 / duration_ms).round(4)
    end

    def artifact_for(started_at)
      @output_dir.join("verification-benchmark-#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
    end

    def persist(artifact, payload)
      FileUtils.mkdir_p(artifact.dirname)
      artifact.write(JSON.pretty_generate(payload))
      JSON.parse(artifact.read)
    end

    def with_mode_settings
      original_extraction_reuse = VerifyLabelJob.extraction_reuse_enabled
      VerifyLabelJob.extraction_reuse_enabled = extraction_reuse_enabled?
      yield
    ensure
      VerifyLabelJob.extraction_reuse_enabled = original_extraction_reuse
    end

    def extraction_reuse_enabled?
      @mode != "cold"
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    end
  end
end
