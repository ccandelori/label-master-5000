# frozen_string_literal: true

require "fileutils"

module Performance
  # Exercises the Paddle sidecar directly against real attached artwork and
  # persists latency/error data separately from full verification. This keeps
  # sidecar availability and OCR cost visible even when the app falls back to
  # Tesseract during normal verification.
  class OcrSidecarStress
    def initialize(batch_id:, limit:, output_dir:, client:)
      @batch_id = batch_id
      @limit = parsed_limit(limit)
      @output_dir = Pathname(output_dir)
      @client = client
    end

    def run
      selected = applications.to_a
      started_wall = Time.current
      started = monotonic_ms
      records = selected.map { |application| measure_application(application) }
      completed_wall = Time.current
      artifact = artifact_for(started_wall)
      payload = payload_for(
        applications: selected,
        records: records,
        total_duration_ms: monotonic_ms - started,
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

    def measure_application(application)
      started = monotonic_ms
      pages = @client.read(data: application.artwork.download, content_type: application.artwork.content_type)
      {
        label_application_id: application.id,
        serial_number: application.serial_number,
        brand_name: application.brand_name,
        ok: true,
        page_count: pages.size,
        word_count: pages.sum { |page| page.words.size },
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

    def payload_for(applications:, records:, total_duration_ms:, started_at:, completed_at:, artifact:)
      {
        run_id: artifact.basename(".json").to_s,
        started_at: started_at.iso8601,
        completed_at: completed_at.iso8601,
        artifact_path: artifact.to_s,
        scope: {
          batch_id: @batch_id.presence,
          limit: @limit,
          label_application_ids: applications.map(&:id)
        },
        environment: environment_payload,
        runtime_dependencies: Extraction::RuntimeDependencies.build.report,
        records: records,
        summary: summary(records, total_duration_ms)
      }
    end

    def environment_payload
      config = Rails.application.config.x.extraction
      {
        rails_env: Rails.env,
        ruby_engine: RUBY_ENGINE,
        ruby_version: RUBY_VERSION,
        paddle_url: config.paddle_url,
        paddle_timeout_seconds: config.paddle_timeout_seconds
      }
    end

    def summary(records, total_duration_ms)
      successes = records.count { |record| record[:ok] }
      failures = records.size - successes
      {
        labels: records.size,
        successes: successes,
        failures: failures,
        total_duration_ms: total_duration_ms,
        labels_per_second: per_second(records.size, total_duration_ms),
        record_duration_ms: distribution(records.map { |record| record[:duration_ms] }),
        backpressure_failures: records.count { |record| record[:error_class] == "Extraction::OcrBackpressureError" },
        error_classes: error_classes(records),
        word_count: word_count_summary(records)
      }
    end

    def error_classes(records)
      records.reject { |record| record[:ok] }
             .group_by { |record| record[:error_class] }
             .transform_values(&:count)
    end

    def word_count_summary(records)
      counts = records.filter_map { |record| record[:word_count] }
      {
        total: counts.sum,
        distribution: distribution(counts)
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
      @output_dir.join("ocr-sidecar-stress-#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
    end

    def persist(artifact, payload)
      FileUtils.mkdir_p(artifact.dirname)
      artifact.write(JSON.pretty_generate(payload))
      JSON.parse(artifact.read)
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    end
  end
end
