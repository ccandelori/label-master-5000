# frozen_string_literal: true

require "yaml"

module ReviewCorpus
  # Deterministic regression runner for known label-verification failures.
  # Fixtures provide application values plus fake OCR/VLM evidence so CI
  # tests verifier behavior without external OCR or model calls.
  class Runner
    Result = Data.define(:name, :ok, :duration_ms, :overall_verdict, :failures) do
      def to_h
        {
          name: name,
          ok: ok,
          duration_ms: duration_ms,
          overall_verdict: overall_verdict,
          failures: failures
        }
      end
    end

    class FixtureOcrEngine
      def initialize(pages:)
        @pages = pages
      end

      def read(data:, content_type:)
        @pages
      end
    end

    class FixtureAdjudicator
      def initialize(results:)
        @results = results
      end

      def adjudicate(fields:, image:, content_type:)
        @results
      end
    end

    module NullProgressReporter
      module_function

      def stage_started(attempt:, stage:)
      end

      def stage_finished(attempt:, stage:, duration_ms:)
      end
    end

    def initialize(fixtures_dir:)
      @fixtures_dir = Pathname(fixtures_dir)
    end

    def run
      results = fixture_paths.map { |path| run_fixture(path) }
      {
        summary: {
          cases: results.size,
          passed: results.count(&:ok),
          failed: results.count { |result| !result.ok },
          duration_ms: distribution(results.map(&:duration_ms))
        },
        cases: results.map(&:to_h)
      }
    end

    private

    def fixture_paths
      @fixtures_dir.glob("*.corpus").sort
    end

    def run_fixture(path)
      fixture = YAML.safe_load(path.read, permitted_classes: [ Symbol ], aliases: false).deep_stringify_keys
      started = monotonic_ms
      application = create_application(attributes: fixture.fetch("application"), fixture_name: fixture.fetch("name"))
      verification = verifier_for(fixture).verify(
        label_application: application,
        attempt: application.verification_attempts.create!,
        mode: VerifierV2::BLOCKING_MODE
      )
      failures = compare(verification: verification, expected: fixture.fetch("expected"))
      Result.new(
        name: fixture.fetch("name", path.basename(".yml").to_s),
        ok: failures.empty?,
        duration_ms: monotonic_ms - started,
        overall_verdict: verification.overall_verdict,
        failures: failures
      )
    rescue StandardError => e
      Result.new(
        name: path.basename(".yml").to_s,
        ok: false,
        duration_ms: monotonic_ms - started,
        overall_verdict: nil,
        failures: [ "#{e.class.name}: #{e.message}" ]
      )
    end

    def verifier_for(fixture)
      VerifierV2::Runner.new(
        ocr_engine: FixtureOcrEngine.new(pages: pages_from(fixture.fetch("ocr_pages"))),
        ocr_engine_key: "review-corpus-v1-#{fixture.fetch("name")}",
        escalation_engine: FixtureOcrEngine.new(pages: pages_from(fixture.fetch("ocr_pages"))),
        vlm_adjudicator: FixtureAdjudicator.new(results: adjudications_from(fixture.fetch("vlm_adjudications", []))),
        vlm_provider: nil,
        vlm_model: nil,
        progress_reporter: NullProgressReporter,
        ocr_readiness: -> {
          Extraction::RuntimeDependencies::OcrReadiness.new(ready: true, latency_ms: 0, error_message: nil)
        },
        config: Rails.application.config.x.extraction
      )
    end

    def create_application(attributes:, fixture_name:)
      application = LabelApplication.new(attributes)
      application.source_kind = "registry_eval"
      application.artwork.attach(
        io: StringIO.new("review-corpus-label-#{fixture_name}"),
        filename: "#{attributes.fetch("serial_number")}.png",
        content_type: "image/png"
      )
      application.save!
      application
    end

    def pages_from(definitions)
      definitions.map do |definition|
        Extraction::OcrClient::Page.new(
          number: Integer(definition.fetch("number")),
          width: Integer(definition.fetch("width")),
          height: Integer(definition.fetch("height")),
          words: words_from(definition.fetch("words"))
        )
      end
    end

    def words_from(definitions)
      definitions.map do |definition|
        Extraction::OcrClient.build_word(
          text: definition.fetch("text"),
          x: Integer(definition.fetch("x")),
          y: Integer(definition.fetch("y")),
          width: Integer(definition.fetch("width")),
          height: Integer(definition.fetch("height")),
          confidence: Float(definition.fetch("confidence"))
        )
      end
    end

    def adjudications_from(definitions)
      definitions.map do |definition|
        Extraction::VlmAdjudicator::Result.new(
          field: definition.fetch("field"),
          status: definition.fetch("status"),
          page: definition["page"],
          reason: definition.fetch("reason", ""),
          model_id: definition.fetch("model_id", "gpt-5.4-mini")
        )
      end
    end

    def compare(verification:, expected:)
      failures = []
      expected_overall = expected.fetch("overall_verdict")
      if verification.overall_verdict != expected_overall
        failures << "overall_verdict expected #{expected_overall.inspect}, got #{verification.overall_verdict.inspect}"
      end
      failures.concat(field_failures(verification: verification, expected_fields: expected.fetch("field_verdicts", {})))
      failures.concat(absent_text_failures(verification: verification, absent_texts: expected.fetch("absent_extraction_text", [])))
      failures
    end

    def field_failures(verification:, expected_fields:)
      checks = verification.field_checks.index_by(&:field)
      expected_fields.filter_map do |field, verdict|
        actual = checks[field]&.verdict
        next if actual == verdict

        "#{field} expected #{verdict.inspect}, got #{actual.inspect}"
      end
    end

    def absent_text_failures(verification:, absent_texts:)
      extraction = JSON.generate(verification.extraction)
      absent_texts.filter_map do |text|
        next unless extraction.include?(text)

        "extraction unexpectedly included #{text.inspect}"
      end
    end

    def distribution(values)
      sorted = values.compact.map(&:to_f).sort
      return { count: 0, p50: nil, p95: nil, max: nil } if sorted.empty?

      {
        count: sorted.size,
        p50: percentile(sorted, 0.50),
        p95: percentile(sorted, 0.95),
        max: sorted.last.round(2)
      }
    end

    def percentile(sorted, quantile)
      index = (sorted.size * quantile).ceil - 1
      sorted[index.clamp(0, sorted.size - 1)].round(2)
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
