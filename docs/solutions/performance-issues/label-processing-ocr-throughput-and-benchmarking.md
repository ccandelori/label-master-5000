---
title: Label Processing OCR Throughput and Benchmarking
date: 2026-06-12
category: performance-issues
module: Label verification pipeline
problem_type: performance_issue
component: background_job
symptoms:
  - Label verification appeared abysmally slow and CPU-bound.
  - PaddleOCR sidecar failures made runs look unstable or fallback-heavy.
  - OCR stress runs produced intermittent 429 sidecar busy errors.
  - Fresh labels still depended on a slow multimodal vision extraction call.
  - Benchmark numbers changed depending on unrelated local processes.
  - Batch controllers owned import, retry, export, and enqueue behavior directly.
root_cause: missing_workflow_step
resolution_type: code_fix
severity: high
related_components:
  - rails_model
  - rails_controller
  - tooling
tags:
  - ocr
  - paddle
  - performance
  - solid-queue
  - benchmarking
  - rails-domain-models
---

# Label Processing OCR Throughput and Benchmarking

## Problem

Label processing was slow enough to be unacceptable, and the failure mode was hard to reason about because multiple issues were stacked together: expensive OCR, oversized image handling, sidecar admission limits, stale background/evaluation processes, and Rails controllers/jobs owning too much workflow logic.

The important lesson is that this was not primarily a "rewrite Ruby/Python" problem. The first useful wins came from bounding and instrumenting the OCR sidecar, measuring real stages, isolating benchmark runs, and moving Rails orchestration back behind model verbs.

## Symptoms

- PaddleOCR direct reads were taking several seconds per image on CPU.
- A benchmark run against the seeded registry sample initially showed `2` failures out of `14`; both failures were `Extraction::OcrError` wrapping HTTP `429` from the sidecar.
- That error shape was wrong: `429` means the Paddle sidecar is healthy but busy. Treating it as a generic `OcrError` let `FallbackOcr` switch to Tesseract and persist lower-quality geometry under ordinary load.
- The truly cold path still called the external vision extractor when extraction reuse missed. Cached verification was fast, but a fresh label could still be dominated by a slow multimodal model request.
- After OCR-first was wired in, the first cold benchmark was still too slow because OCR-first reused the legacy enriched OCR engine. That engine does three non-PDF reads per image: original, upscaled, and inverted. This made one logical label spend roughly three PaddleOCR passes in `ocr_pooled_pages`.
- A later batch upload exposed a worse production bug: explicit batch `ocr_first` still used `FallbackOcr`, so a dead Paddle sidecar could fall back to weaker Tesseract output and persist hard `fail` verdicts as if the primary OCR system had read the label.
- Sidecar metrics showed rejected-busy reads while another `ruby bin/rails eval:run[3,40]` process was still active and sending OCR work.
- Full verification became fast once extraction reuse and OCR cache hits were isolated: the registry sample ran in `2.902s` total with `100%` OCR cache hits.
- Batch submission used `update_all`, which skipped `LabelApplication` callbacks and could leave reviewer queue broadcasts stale.

## What Didn't Work

- Treating the slow path as proof that MRI Ruby, Python, or the Python GIL was the primary bottleneck. The expensive work was mostly native OCR/image processing, external model calls, Active Storage I/O, and local process contention.
- Running OCR benchmarks while stale evaluation processes were still active. This contaminated the sidecar with concurrent requests and produced false `429` instability.
- Looking only at end-to-end latency. Without stage instrumentation, OCR failures, cache misses, model calls, and Rails persistence looked like one indistinct slowdown.
- Letting a busy Paddle sidecar fall through to Tesseract. That made normal load look "stable" while quietly degrading the verifier's evidence quality.
- Letting explicit batch OCR fall through to Tesseract when Paddle was unreachable. That made an operational outage look like legitimate compliance failures.
- Optimizing the cached path and assuming cold labels were solved. Extraction reuse and OCR cache hit runs answer a different question from a no-cache, no-reuse label.
- Bypassing Rails model behavior with `update_all` for batch submission. It was faster in the narrow SQL sense but skipped the callback that refreshes reviewer queues.
- Resetting or reseeding destructively. The development DB already had substantial local data (`167` batches, `751` labels), so `bin/rails db:seed` was run non-destructively and skipped because the `TTB registry sample` batch already existed.

## Solution

### 1. Keep the sidecar bounded and observable

The Paddle sidecar now exposes readiness and metrics, rejects excess concurrent work explicitly, and recycles by completed reads instead of raw HTTP request count. This matters because health checks should not consume the recycle budget, and PaddleOCR's CPU memory arena grows with large images.

Useful checks:

```bash
curl -sS --max-time 2 http://127.0.0.1:8765/readyz
curl -sS --max-time 2 http://127.0.0.1:8765/metrics
```

For isolated local analysis, start the sidecar with no automatic recycle:

```bash
OCR_MAX_READS=0 OCR_PORT=8765 bash ocr_service/bin/serve
```

Stop it when done so later agents do not inherit extra local state.

### 2. Do not benchmark against a busy sidecar

Before trusting OCR analysis, check for active Rails/eval/job processes that can call the sidecar:

```bash
ps aux | rg "(rails eval:run|bin/jobs|bin/dev|uvicorn|ocr_service)"
```

In the 2026-06-12 run, a stale `ruby bin/rails eval:run[3,40]` process was still consuming OCR and CPU. The first stress artifact produced `429` failures:

```text
tmp/perf/ocr-sidecar-stress-20260612T163308Z.json
labels: 14
successes: 12
failures: 2
failure class: Extraction::OcrError
failure body: ocr sidecar responded 429: {"error":"ocr sidecar busy", ...}
```

After stopping the stale eval process, the clean run succeeded:

```text
tmp/perf/ocr-sidecar-stress-20260612T163629Z.json
labels: 14
successes: 14
failures: 0
total_duration_ms: 53000
p50: 3679 ms
p95: 7133 ms
```

The Rails client now treats sidecar busy as typed backpressure. `PaddleOcrClient` retries HTTP `429` responses using the sidecar's `Retry-After` header when present. If the retry budget is exhausted, it raises `Extraction::OcrBackpressureError`, which is not an `OcrError`; `FallbackOcr` therefore cannot turn a healthy-but-busy Paddle service into a Tesseract-backed verification.

### 3. Use the performance tasks instead of ad hoc timing

The project has analysis tasks for the direct sidecar and full persisted verification:

```bash
bin/rails 'perf:ocr_sidecar[1,14]'
bin/rails 'perf:verify_labels[1,14,cold]'
bin/rails 'perf:verify_labels[1,14,cached]'
bin/rails 'perf:verify_labels[1,14,legacy_vision]'
```

`perf:ocr_sidecar` exercises PaddleOCR directly against attached artwork.

`perf:verify_labels` runs the Rails verification path and records stage-level timing from `ActiveSupport::Notifications`. Use `cold` when testing the production cold-label target: it disables extraction reuse and bypasses OCR cache without deleting existing rows. Use `cached` to measure the production path with caches allowed. Use `legacy_vision` to compare against the old external vision-model path.

Clean full verification run from the same day:

```text
tmp/perf/verification-benchmark-20260612T163747Z.json
labels: 14
successes: 14
failures: 0
total_duration_ms: 2902
labels_per_second: 4.8243
ocr_cache.hit_rate: 1.0
ocr_engine.fallbacks: 0
```

That historical artifact means cached verification was fast; it did not prove cold labels were solved. Current artifacts include the benchmark mode, extraction reuse/cache policy, backpressure event counts, and a `performance_target` block that reports whether cold p50 met the five-second target.

Verification jobs now run on the dedicated `verification` queue and default `VERIFY_CONCURRENCY` to `OCR_CONCURRENCY` when no override is provided. The default one-reader sidecar should therefore receive one verification at a time. If production runs multiple sidecars or raises `OCR_CONCURRENCY`, raise `VERIFY_CONCURRENCY` deliberately and confirm `/up/dependencies` still reports `aligned: true`.

### 4. Make quality mode the production cold path

The default verification mode is quality mode (`EXTRACTION_MODE=quality`). With no provider/model override, `VerifyLabelJob` tries the local OCR page pool first and builds a schema-compatible payload via `Extraction::OcrFirstPayload`. If that OCR-first attempt produces a clean pass/pass-with-note, the job persists the result under `quality-v1`.

If the OCR-first attempt would persist a hard `fail`, `needs_review`, or `request_retake`, quality mode falls back before persisting. It first reuses an existing legacy vision extraction for the same artwork/model when present; otherwise it runs the configured legacy vision extractor and then persists the final verdict under `quality-v1`. This prevents low OCR recall from turning prior passes into new failures.

The configured VLM fallback defaults to the OpenAI connector with `gpt-5.4-mini`; keep larger models as explicit comparison runs so ordinary quality-mode fallbacks do not silently inherit their latency and cost.

This matters because a cold label cannot hit a five-second CPU target while waiting on an 80-130 second multimodal request, but pure OCR is not quality-equivalent to vision. OCR is a fast first pass. Legacy vision is the quality fallback when OCR cannot prove the label is compliant. Visual-only attributes, such as warning boldness, remain `nil` in OCR-only attempts and surface as `needs_review` unless legacy fallback supplies them.

Pure `ocr_first` payloads are application-conditioned, so persisted extraction reuse is intentionally disabled for explicit OCR-first diagnostic runs. Quality-mode payloads are reusable under the `quality-v1` model id: if the same artwork fingerprint has already produced a quality result, `VerifyLabelJob` reuses it before running OCR-first or legacy fallback again. That avoids repeated 20-90 second fallback loops on repaired multi-panel records.

Legacy vision payloads also remain eligible for extraction reuse because they are application-blind, and quality mode deliberately reuses those legacy payloads before making a new external call when no `quality-v1` result exists.

Batch upload pre-checks are deliberately different. `BatchesController#create` and `Batches::RetriesController#create` enqueue `VerifyLabelJob` with explicit mode `ocr_first`, while single-label creates, edits, and re-checks leave mode blank and therefore use quality mode. The batch page is a triage queue: it must surface fast conservative findings and keep moving. Do not switch batch upload back to implicit quality mode unless the cold vision fallback is eliminated or made asynchronous; ordinary non-passing OCR rows will otherwise spend minutes in `vision_extraction` plus `ocr_refinement`.

OCR-first uses the single-pass Paddle engine and cache key:

```ruby
Extraction::OcrFactory.build_fast
Extraction::OcrFactory.fast_cache_key
```

Do not change that back to `Extraction::OcrFactory.build` without rerunning the cold benchmark. `build` wraps the base engine in `Extraction::EnrichedOcr`, which is intentionally three-pass and useful for legacy refinement, but it pushed cold OCR-first p50 from `3.794s` to `12.035s` on the seeded sample.

Batch OCR-first is also intentionally strict. `Extraction::OcrFactory.build_fast` uses Paddle directly when `EXTRACTION_OCR_ENGINE=paddle`; it must not wrap Paddle in `FallbackOcr`. If Paddle is unreachable, `Extraction::OcrConnectionError` bubbles to `VerifyLabelJob`, which retries and eventually records an operational `error` instead of persisting Tesseract-derived findings as production evidence.

Batch admission is health-gated before persistence. `BatchesController#create` and `Batches::RetriesController#create` call `Extraction::OcrGateway.ready`, which checks `/healthz` and `/readyz` on the Paddle backend. If the configured Paddle URL is local and `EXTRACTION_OCR_AUTO_START` is enabled, the gateway starts `ocr_service/bin/serve`, waits for readiness, then admits the batch. A failed readiness check blocks the upload/retry with a visible message only after self-healing fails. This is deliberate: a batch that depends on OCR should not start when its OCR backend is known down.

Explicit `ocr_first` verdicts are conservative. A rules-engine `fail` produced from OCR-only evidence is downgraded to `needs_review` with a note explaining that OCR could not prove a rejection. This keeps batch pre-checks fast and useful without turning OCR recall misses into automated hard failures. Quality mode still uses hard OCR failures internally to decide whether to fall back to legacy vision before persisting a final `quality-v1` result.

Pre-review and pre-check mean the same manufacturer sandbox flow. Its form and re-check action now default to `Quality pre-check` (`demo_model=quality`). The configured vision models remain available, but their labels are prefixed with `Compare:` and choosing one intentionally runs that legacy vision model for comparison.

### 5. Move Rails workflow back to model verbs

Controllers were doing too much work directly. The refactor moved batch and label workflows into model-owned verbs:

```ruby
class LabelApplication < ApplicationRecord
  def verify_later(provider:, model:, mode: nil)
    args = [ id, provider, model ]
    args << mode if mode
    VerifyLabelJob.perform_later(*args)
  end

  def submit_to_ttb
    return false if submitted?

    submitted!
    true
  end

  def unchecked_or_error?
    verification = latest_verification
    verification.nil? || verification.error?
  end
end
```

```ruby
class Batch < ApplicationRecord
  def retry_failed_verifications_later(provider:, model:, mode: nil)
    retried = 0

    label_applications.find_each do |application|
      next unless application.unchecked_or_error?

      application.verify_later(provider: provider, model: model, mode: mode)
      retried += 1
    end

    retried
  end

  def submit_to_ttb
    submitted = 0

    label_applications.pre_review.find_each do |application|
      submitted += 1 if application.submit_to_ttb
    end

    submitted
  end
end
```

Batch export and retry became resource-shaped controllers:

```ruby
module Batches
  class RetriesController < ApplicationController
    def create
      batch = Batch.find(params[:batch_id])
      readiness = Extraction::OcrGateway.ready
      return redirect_to batch, alert: readiness.message unless readiness.ok?

      retried = batch.retry_failed_verifications_later(provider: nil, model: nil, mode: "ocr_first")
      redirect_to batch, notice: "Re-queued #{retried} #{'row'.pluralize(retried)}."
    end
  end
end
```

The routes now use nested singular resources:

```ruby
resources :batches, only: %i[new create show] do
  scope module: :batches do
    resource :export, only: :show, defaults: { format: :csv }
    resource :retry, only: :create
  end
  resource :submission, only: :create, controller: "batch_submissions"
end
```

### 6. Replace `update_all` where callbacks matter

Do not bulk-submit a batch with:

```ruby
batch.label_applications.pre_review.update_all(channel: "submitted", updated_at: Time.current)
```

That skips the `LabelApplication` `after_commit` callback that refreshes the reviewer queue.

Use the domain method instead:

```ruby
count = batch.submit_to_ttb
```

The method iterates records and calls `LabelApplication#submit_to_ttb`, preserving model behavior.

## Why This Works

The architecture now separates three questions that were previously tangled:

1. Is OCR itself slow or unavailable?
2. Is Rails verification slow after extraction data is already available?
3. Is cold verification still calling an external vision model?
4. Is the benchmark isolated from other local work?

Direct sidecar stress answers the first question. Full verification benchmarking answers the second. Process and sidecar metrics answer the third.

The Rails refactor also makes production behavior easier to preserve. Controllers now call model verbs instead of duplicating loops and queueing decisions, and batch submission no longer bypasses callbacks.

The measured state after the fix:

- Direct single-pass PaddleOCR on 14 seeded labels: `55.580s`, no failures, p50 `3.791s`, p95 `7.602s`.
  Artifact: `tmp/perf/ocr-sidecar-stress-20260612T182944Z.json`.
- Cold OCR-first before removing enriched OCR from the critical path: `169.182s`, p50 `12.035s`, p95 `21.910s`, cold target not met.
  Artifact: `tmp/perf/verification-benchmark-20260612T183051Z.json`.
- Cold OCR-first after switching to single-pass OCR: `54.771s`, no failures, p50 `3.794s`, p95 `7.690s`, cold p50 target met, fallbacks `0`, backpressure events `0`.
  Artifact: `tmp/perf/verification-benchmark-20260612T183646Z.json`.
- Cached OCR-first after warming the single-pass OCR cache: `0.683s`, no failures, p50 `42ms`, p95 `193ms`, OCR cache hit rate `100%`, fallbacks `0`.
  Artifact: `tmp/perf/verification-benchmark-20260612T183901Z.json`.
- A sidecar `OCR_MAX_INPUT_SIDE=1800` A/B run did not improve this sample: direct p50 was `4.212s` and p95 was `7.568s`.
  Artifact: `tmp/perf/ocr-sidecar-stress-20260612T184211Z.json`. The default `2500` cap was left in place.

The correctness gate exposed why pure OCR-first is not production-ready. Scoring the latest `ocr-first-v1` verifications for batch `1` reported `0` clean approved labels, `13` flagged, and `1` retake. Two concrete regressions were reproduced: `HARPOON` moved from legacy `pass_with_note` to OCR-first `fail`, and `GUINNESS` moved from legacy `pass` to OCR-first `fail`. Replaying those records through quality mode persisted `quality-v1` results of `pass_with_note` and `pass`, respectively, by reusing their prior legacy extractions. Treat OCR-first as a fast attempt, not as the production quality contract.

The next full-batch pass found a separate seed-data problem: `db/seeds.rb` attached only the first/brand image from the harvested registry manifest and discarded available back panels. Several approved labels were therefore being judged from incomplete evidence. Seeding now attaches a `Back` panel when the manifest provides one and repairs missing back attachments on an existing `TTB registry sample` batch. After repairing the local batch, `quality-v1` replayed with no approved-label hard failures; remaining approved-label findings were `needs_review` items such as applicant/trade-name mismatch, brand-label placement ambiguity, warning paragraph continuity, or incomplete country-origin evidence. Cached quality replay artifact: `tmp/perf/verification-benchmark-20260612T201404Z.json` (`14/14` success, p50 `44ms`, p95 `1.776s`, OCR cache hit rate `100%`, extraction reuse `14/14`).

Cold labels that require a fresh external vision fallback are still not within the five-second target; repaired multi-panel labels observed fallback latencies from roughly `15s` to `93s`. The five-second path is the local OCR path plus conservative review outcomes, or a warm quality/legacy reuse path. Do not describe vision fallback as solved for cold latency.

## Prevention

- Do not conclude "rewrite the stack" before collecting stage metrics. First check OCR cache hit rate, fallback count, sidecar busy count, and per-stage timings.
- Do not let `Extraction::OcrBackpressureError` inherit from `Extraction::OcrError`. Busy sidecar responses must retry or fail loudly; they must not trigger OCR fallback.
- Do not let pure OCR-first persist hard production failures by default. Quality mode must fall back to legacy vision/reuse before finalizing a non-passing OCR verdict.
- Do not let explicit batch OCR-first use `FallbackOcr`. A sidecar outage must block or retry; it must not silently switch OCR engines and manufacture compliance failures.
- Do not let batch upload or batch retry enqueue OCR work without `Extraction::OcrGateway.ready`. That gateway owns local sidecar self-healing through `Extraction::OcrSupervisor`; do not bypass it with direct `/healthz` checks in controllers.
- Do not make quality mode skip `quality-v1` reuse. Only explicit `ocr_first` should bypass persisted extraction reuse.
- Do not seed or evaluate registry labels from only the first/brand image when the manifest includes a back panel; incomplete artwork creates false compliance failures.
- Do not run OCR-first through `Extraction::EnrichedOcr` on the cold critical path. That is a three-pass OCR mode and will blow the five-second target on ordinary large labels.
- Do not let pre-review default to a provider/model option. Any `provider:model` value forces an explicit comparison run; quality mode must be the default `quality` choice.
- Do not set `VERIFY_CONCURRENCY` higher than sidecar capacity without adding OCR capacity. A single `OCR_CONCURRENCY=1` sidecar plus four verification workers creates predictable 429 backpressure.
- Do not compare cached and cold benchmark artifacts as if they measure the same thing. Check the artifact's `scope.mode`, `extraction_reuse_enabled`, and `ocr_cache_enabled` fields first.
- Do not change sidecar OCR model, input-size cap, or OCR factory cache-key semantics without bumping the relevant cache version and rerunning both cold timing and eval scoring.
- Do not call OCR-first production-ready for auto-approval from speed alone. Pair `perf:verify_labels[1,14,cold]` with `eval:score[1,quality-v1]`; use `eval:score[1,ocr-first-v1]` only as a diagnostic for the fast OCR attempt.
- Do not run performance analysis while old eval, job, or dev processes are active. Check process state and sidecar metrics first.
- Do not use `update_all` for workflow state transitions that have callbacks, broadcasts, validations, or enum behavior.
- Do not casually reset the development DB to reseed. Inspect existing batches and labels first.
- Keep benchmark artifacts under `tmp/perf/` and reference exact filenames in handoffs.
- Prefer Rails model verbs for domain workflows and keep controllers/resource endpoints thin.

Useful validation commands from the refactor:

```bash
bin/rails test
bin/rubocop --cache false app/models/batch.rb app/models/label_application.rb app/controllers/batches_controller.rb app/controllers/batches/exports_controller.rb app/controllers/batches/retries_controller.rb
```

If local Postgres access fails in the sandbox with `Operation not permitted`, rerun Rails tests with approved local DB access rather than changing database configuration.

## Related Issues

- Sidecar stability and instrumentation changes live in `ocr_service/app.py`, `ocr_service/bin/serve`, `app/lib/extraction/paddle_ocr_client.rb`, `app/lib/extraction/fallback_ocr.rb`, `app/lib/extraction/ocr_cache.rb`, and `app/lib/extraction/refinement.rb`.
- OCR-first extraction internals live in `app/lib/extraction/ocr_first_payload.rb`, `app/lib/extraction/ocr_page_pool.rb`, `app/lib/extraction/ocr_factory.rb`, and `app/jobs/verify_label_job.rb`. Batch OCR readiness lives in `app/lib/extraction/ocr_gateway.rb`; local sidecar ownership lives in `app/lib/extraction/ocr_supervisor.rb`. Production quality mode lives in `VerifyLabelJob` and must remain the default path.
- Rails domain refactor lives in `app/models/batch.rb`, `app/models/label_application.rb`, `app/controllers/batches/exports_controller.rb`, `app/controllers/batches/retries_controller.rb`, and `config/routes.rb`.
- Benchmark tools live in `app/lib/performance/ocr_sidecar_stress.rb`, `app/lib/performance/verification_benchmark.rb`, and `lib/tasks/perf.rake`.
