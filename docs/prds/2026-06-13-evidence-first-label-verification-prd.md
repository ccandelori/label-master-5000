---
title: Evidence-First Label Verification
type: prd
date: 2026-06-13
status: draft
related:
  - docs/plans/2026-06-13-001-evidence-first-verifier-v2.md
  - docs/plans/2026-06-12-001-perf-production-label-throughput-plan.md
  - docs/solutions/performance-issues/label-processing-ocr-throughput-and-benchmarking.md
---

# Evidence-First Label Verification PRD

## Problem Statement

LabelMaster 5000 exists to verify label applications quickly, reliably, and with evidence a human reviewer can trust.

The current verification experience does not yet meet that standard. Reviews can appear to stall, fail invisibly, or produce findings that are not grounded in text actually present on the label. Some prior passes now fail because OCR and VLM evidence is treated too authoritatively. Some slow or unavailable backends look like label problems instead of operational problems. Some generated evidence contains text the model claims to have found even when the label image does not say that.

The user needs a production-grade verifier that can process real COLA-style label records fast enough for interactive review, surface uncertainty honestly, and prevent regressions as new edge cases are discovered.

This is not primarily a language-runtime problem. Rewriting Rails, switching to JRuby, or replacing the app with Java, Go, Python, or ECMAScript would not solve the core product failure. The core failure is that the verifier does not yet have a trustworthy evidence pipeline, a durable attempt lifecycle, a latency budget, and a regression harness tied to real labels.

## Solution

Build an evidence-first verification flow that keeps the existing Rails product shell but replaces the verifier core with a durable, observable, OCR-grounded pipeline.

From the user's perspective:

- Every label review starts visibly and ends in a clear state.
- The app never silently fails to create a review.
- Easy labels complete in roughly one to five seconds when the worker is ready.
- Ambiguous labels either complete or become `needs_review` within roughly ten seconds.
- Operational failures become visible `error` states, not fake compliance findings.
- Findings show application values, observed label values, and evidence.
- VLM output is used only to adjudicate ambiguity, not to invent source text.
- Existing screenshots and discovered failures become regression fixtures.

The experience should make the reviewer feel that the system is fast, honest, and useful even when it cannot decide automatically.

## Goals

- Verify normal cold labels in roughly five seconds when OCR dependencies are ready.
- Keep ambiguous or difficult labels under roughly ten seconds before producing `needs_review` or `error`.
- Persist a verification attempt before any expensive processing begins.
- Separate queue wait time from processing time.
- Ground every automated `pass`, `pass_with_note`, or `fail` in observed evidence.
- Make weak evidence become `needs_review` instead of false failure.
- Make backend failures become `error` instead of compliance findings.
- Prevent VLM hallucinated text from becoming persisted label evidence.
- Preserve a reviewable audit trail for each field-level finding.
- Build a regression corpus from the real labels that have exposed failures.

## Non-Goals

- Rewriting the whole Rails app.
- Replacing the product with a pure OCR service.
- Making a VLM decide full regulatory compliance from a single prompt.
- Training a custom OCR or VLM model in this phase.
- Relying on cloud GPU training or expensive fine-tuning.
- Running every OCR preprocessing strategy on every image.
- Treating cached benchmark speed as proof that cold labels are fast.
- Treating unavailable OCR or model providers as legitimate label failures.
- Achieving perfect automation for every label shape. Human review remains part of the product.

## User Stories

1. As a reviewer, I want every submitted label to show whether it is queued, processing, completed, needs review, failed, or errored, so that I know work is actually happening.

2. As a reviewer, I want labels to finish quickly when they are straightforward, so that review mode feels usable for real batches.

3. As a reviewer, I want hard labels to become `needs_review` instead of hanging indefinitely, so that I can keep moving through the queue.

4. As a reviewer, I want operational failures to be clearly labeled as errors, so that I do not mistake system outages for label defects.

5. As a reviewer, I want each finding to show the application value and the observed label value, so that I can understand the comparison.

6. As a reviewer, I want findings to show evidence locations on the label, so that I can visually confirm what the system found.

7. As a reviewer, I want the system to avoid drawing strokes over tiny text, so that evidence overlays do not obscure the label.

8. As a reviewer, I want spotlight-style evidence highlighting, so that I can inspect text without the UI damaging readability.

9. As a reviewer, I want text findings to be based on observed OCR or image-region evidence, so that I can trust that the system is not inventing label text.

10. As a reviewer, I want uncertain matches to be marked `needs_review`, so that close calls are escalated instead of incorrectly failed.

11. As a reviewer, I want harmless punctuation, casing, spacing, and line-break differences to avoid false failures, so that I focus on meaningful issues.

12. As a reviewer, I want hyphenated line breaks in statutory warnings to be handled correctly, so that valid warnings are not failed because OCR inserted a space.

13. As a reviewer, I want rotated warning text to be detected where feasible, so that side-panel warnings are not missed.

14. As a reviewer, I want wrapped government warning text to be compared as a normalized statement, so that ordinary label layout does not create false wording failures.

15. As a reviewer, I want paragraph-continuity checks to surface layout uncertainty, so that the system does not fail a valid label merely because OCR saw multiple lines.

16. As a reviewer, I want vodka seltzer to be treated differently from straight vodka, so that class/type rules do not apply the wrong ABV threshold.

17. As a reviewer, I want flavor-only fanciful-name displays to be handled with notes or review when appropriate, so that short label displays do not create automatic failures.

18. As a reviewer, I want name and address checks to allow meaningful close matches, so that legal formatting differences do not drown the queue in false failures.

19. As a reviewer, I want front, back, and neck labels to be associated correctly with an application, so that supporting artwork is not treated as the wrong primary panel.

20. As a reviewer, I want duplicate or partial artwork to be detected or escalated, so that imported records with bad artwork do not poison results.

21. As a reviewer, I want old findings to be reproducible after reseeding, so that quality does not degrade silently between implementation passes.

22. As a reviewer, I want a single details/review experience, so that I do not need to jump between duplicated pages to inspect evidence and make decisions.

23. As a reviewer, I want one clear action from the queue into the detail/review view, so that the queue does not create navigation ambiguity.

24. As a batch uploader, I want CSV upload errors to name the exact missing or mismatched columns, so that I can fix input files quickly.

25. As a batch uploader, I want batch validation to fail before processing when required images or columns are missing, so that I do not waste verification time on invalid batches.

26. As a batch uploader, I want batch progress to update while work is running, so that I can tell the system has not stalled.

27. As a batch uploader, I want the system to process labels in parallel up to a safe capacity limit, so that throughput improves without overwhelming OCR.

28. As a batch uploader, I want failed operational jobs to be retryable, so that a temporary backend failure does not require a full reimport.

29. As an operator, I want OCR backend readiness to be visible before batch work starts, so that unavailable OCR does not create fake failed labels.

30. As an operator, I want queue wait, OCR time, VLM time, rules time, and total duration to be recorded separately, so that I can find the actual bottleneck.

31. As an operator, I want model provider errors and response bodies recorded safely, so that schema or API failures can be diagnosed without guessing.

32. As an operator, I want OCR artifacts cached by artwork and OCR configuration, so that repeated review of the same label does not redo expensive work unnecessarily.

33. As an operator, I want sidecar or process failures to be isolated from compliance verdicts, so that infrastructure instability does not corrupt label findings.

34. As an operator, I want p50, p95, max, and failure counts for cold labels, so that production readiness is measured against real latency distribution.

35. As an operator, I want cached benchmarks clearly separated from cold benchmarks, so that performance claims are not misleading.

36. As an operator, I want a corpus of known tricky labels, so that every fix can be regression-tested before release.

37. As a developer, I want a narrow verifier interface, so that the UI and queue can call the verifier without knowing OCR/VLM internals.

38. As a developer, I want the OCR evidence store to be testable without the full Rails UI, so that OCR parsing and normalization bugs are easy to isolate.

39. As a developer, I want rules to consume structured evidence, so that compliance logic stays deterministic and unit-testable.

40. As a developer, I want VLM adjudication to use small schemas and focused crops, so that provider latency and schema failures stay bounded.

41. As a developer, I want unsupported model claims rejected by reconciliation, so that hallucinated text cannot become persisted evidence.

42. As a developer, I want every discovered bug to become a fixture expectation, so that the app gets better instead of cycling through regressions.

43. As a developer, I want old and new verifier behavior to be comparable during migration, so that the rollout can be evidence-based.

44. As a developer, I want the app to preserve existing records and UI paths while the verifier core is replaced, so that we reduce delivery risk.

45. As the product owner, I want the system to be honest about what it knows, so that users trust the tool even when it asks for human judgment.

## Product Requirements

### Verification Attempt Lifecycle

- A verification attempt must be persisted before OCR, VLM, or rules execution begins.
- Each attempt must have a visible state: `queued`, `processing`, `passed`, `failed`, `needs_review`, or `error`.
- Attempts must record processing start and finish timestamps.
- Attempts must record queue wait separately from execution duration.
- A processing exception must end in an explicit `error` state with diagnostic context.
- A label should never remain indefinitely pending because a job crashed before persistence.

### Evidence Grounding

- Field findings must distinguish application value from observed label value.
- Observed label values must come from OCR evidence, supported image regions, or explicit human review.
- Findings must include evidence source and location when available.
- Model-only text claims must be reconciled against OCR or image-region evidence before persistence.
- Unsupported model claims must become `ambiguous` or `needs_review`, not hard `pass` or `fail`.

### OCR-First Text Evidence

- Local OCR must be the first production evidence layer.
- OCR output must preserve page dimensions, word text, confidence, and bounding boxes.
- OCR strings must be converted to valid UTF-8 before normalization.
- OCR artifacts must be persisted or cached for reuse and debugging.
- OCR escalation passes should be conditional, based on missing evidence or low confidence.
- Rotation handling must be available for fields commonly printed sideways.

### VLM Adjudication

- VLM calls must be targeted to unresolved fields.
- VLM prompts must include specific application values and candidate evidence.
- VLM calls should prefer crops or focused regions over entire label images when possible.
- VLM schemas must be small enough to avoid provider grammar/schema failures.
- VLM output must classify evidence as `present`, `absent`, or `ambiguous`.
- VLM output must not be treated as source text unless grounded by evidence.

### Rules and Verdicts

- Rules must evaluate structured evidence rather than raw model prose.
- Hard `fail` must require strong evidence.
- Weak OCR, uncertain model output, or missing visual evidence must produce `needs_review`.
- `pass_with_note` should be used for technically different but acceptable matches.
- `not_applicable` should be used when a regulatory check does not apply to the beverage/product class.
- Operational errors must not be converted into rule failures.

### Review Experience

- The details page should absorb the useful parts of review mode.
- The queue should have one clear action into the combined review/detail experience.
- The image pane should support inspection without obscuring text.
- Evidence highlighting should prefer a spotlight mask over text-covering strokes.
- Reviewers should be able to approve, reject, request better image, skip, and undo from the combined view.
- The UI must show current state and progress while processing is active.

### Batch Experience

- Batch CSV validation must happen before verification begins.
- Required columns and missing images must be reported clearly.
- Batch processing must show progress in near real time.
- Batch verification must use bounded parallelism aligned with OCR capacity.
- Batch operational failures must be retryable without reimporting successful rows.
- Batch results must distinguish review findings from infrastructure errors.

### Observability

- Stage timings must be recorded for image prep, OCR, candidate matching, VLM, rules, persistence, and total processing.
- Queue wait must be recorded separately.
- OCR engine, OCR config, OCR version, and cache status must be visible.
- VLM provider, model, schema version, duration, and token usage must be visible when applicable.
- Error records must include error class, actionable message, and backend response context when safe.
- Performance artifacts must report cold and cached results separately.

### Regression Corpus

- Known failures from the journey must become fixture-backed expectations.
- The corpus must include rotated warnings, wrapped warnings, hyphenated statutory text, dense back labels, neck labels, duplicated artwork, vodka seltzer, low-contrast labels, address close matches, and hallucinated text cases.
- Each fixture must define expected field outcomes.
- The corpus must be runnable locally.
- Correctness and latency must both be reported.

## Implementation Decisions

- Keep the Rails application as the product shell.
- Introduce a new verifier core behind a narrow call interface.
- Treat the verifier as a deep module: one simple entry point, many internal responsibilities, heavy isolated test coverage.
- Split evidence acquisition from regulatory judgment.
- Make OCR evidence a first-class persisted or cached artifact.
- Use local OCR as the primary text evidence layer.
- Use VLMs only for bounded adjudication of unresolved fields.
- Use small task-specific schemas instead of one giant regulatory schema.
- Reconcile model claims before persisting them.
- Use deterministic rules over structured evidence.
- Preserve human review as a first-class outcome.
- Make operational errors explicit and visible.
- Separate batch admission, processing, retry, and export concerns.
- Merge review and detail UX around one inspection surface.

## Proposed Deep Modules

- Verification Orchestrator: owns attempt lifecycle, state transitions, stage timing, and final persistence.
- OCR Evidence Store: runs OCR, parses structured OCR output, normalizes text, caches artifacts, and exposes pages/words/lines/boxes.
- Candidate Matcher: finds application values in OCR evidence with fuzzy matching and geometry-aware matching.
- Evidence Reconciler: rejects unsupported VLM claims and merges OCR, crop, and model evidence into field evidence.
- Rules Evaluator: converts structured evidence into field-level findings and overall verdicts.
- VLM Adjudicator: sends focused image/text questions to a small model with compact schemas.
- Review Corpus: stores fixtures, expected outcomes, and latency measurements for known edge cases.
- Progress Reporter: publishes queue, processing, stage, and completion state to the UI.

## Testing Decisions

- Test observable behavior, not private implementation details.
- Every verifier attempt test should assert final state and persisted timing behavior.
- OCR parsing tests should use representative TSV/hOCR samples and binary/invalid encoding cases.
- Candidate matching tests should cover casing, punctuation, spacing, diacritics, hyphenation, line breaks, rotations, and close matches.
- Rules tests should prove uncertainty becomes `needs_review` and strong grounded mismatches become `fail`.
- VLM adjudication tests should use deterministic fake providers and verify schema size, prompt scope, and unsupported-claim rejection.
- Batch tests should cover validation failures, progress states, retry, and operational errors.
- UI/system tests should cover the combined details/review flow and ensure evidence overlays do not obscure text.
- Performance tests should report cold and cached timing separately.
- Regression corpus tests should be added for every user-reported false failure or hallucinated evidence case.

## Acceptance Criteria

- A label verification attempt is persisted before any OCR or VLM work begins.
- A job crash produces a visible `error` verification attempt.
- Easy seeded cold labels complete near the five-second target when OCR is ready.
- Ambiguous labels stop near the ten-second target with `needs_review` or `error`.
- Queue wait is visible separately from processing time.
- Findings never display hallucinated model text as observed label text.
- OCR binary encoding cannot crash text normalization.
- Government warning checks tolerate ordinary wrapping, spacing, and hyphenation.
- Rotated text has a conditional OCR path.
- Vodka seltzer does not inherit straight-vodka ABV rules.
- Close name/address matches can pass with notes or move to review rather than fail automatically.
- Batch upload progress updates while work is running.
- Batch operational failures are retryable.
- The combined details/review page can replace separate review/detail navigation for ordinary review work.
- The regression corpus catches the known false failures before release.

## Launch Gates

- Cold benchmark reports p50, p95, max, queue wait, OCR time, VLM time, and total time.
- Cold benchmark includes real persisted verification attempts.
- Cached benchmark is reported separately.
- Regression corpus passes for known high-risk labels.
- No hard failures are produced from unsupported model-only evidence.
- No operational backend failure is persisted as a compliance failure.
- The UI shows live state for queued and processing labels.
- The reviewer can inspect evidence for every automated hard failure.
- Documentation explains the verifier's evidence contract and failure states.

## Risks

- OCR recall may miss small, rotated, or low-contrast text.
- Conditional OCR escalation can add latency if applied too broadly.
- VLM adjudication can still hallucinate if reconciliation is weak.
- Regression fixtures may initially be too small to catch all real-world label variation.
- Existing data quality issues may continue to produce confusing records until import cleanup is handled.
- Provider latency and schema limits can still affect ambiguous cases.
- UI progress may expose queue bottlenecks that need separate worker tuning.

## Mitigations

- Treat uncertain evidence as `needs_review`.
- Make OCR escalation conditional and measured.
- Reject unsupported model claims.
- Add every discovered failure to the corpus.
- Separate operational errors from compliance findings.
- Keep VLM schemas small and field-specific.
- Measure queue wait separately from processing time.
- Preserve existing app shell while replacing the verifier core incrementally.

## Out of Scope

- Full application rewrite.
- Custom OCR model training.
- Custom VLM fine-tuning.
- GPU deployment tuning.
- External cloud OCR migration as the default path.
- Perfect artwork role detection for every imported record.
- Final legal interpretation beyond encoded rules and reviewer judgment.

## Further Notes

The central lesson from the current journey is that speed and trust cannot be solved independently. A fast verifier that fails valid labels is not useful. A high-quality verifier that silently stalls is not useful. A model that sounds confident while inventing label text is actively dangerous.

The right product shape is an evidence-first review assistant: fast where evidence is clear, cautious where evidence is weak, and transparent at every step.
