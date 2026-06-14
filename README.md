# LabelMaster 5000

Rails application for validating TTB/COLA application records against submitted
label artwork. The main workflow is the Validation page: start from seeded sample
data, upload application PDFs, or enter application values manually, then compare
those values against the label text and artwork.

## What It Does

- Extracts application data and label images from uploaded application PDFs.
- Accepts batch uploads from application PDFs or CSV rows plus label images.
- Runs a fast validation pipeline using local Tesseract OCR and a VLM fallback.
- Persists verification attempts, findings, latency, and historical results.
- Streams single-validation and batch progress updates with Hotwire.
- Keeps reviewer-facing work centered on Validation and History.

The app no longer depends on a PaddleOCR/Python sidecar for the default path.

## Requirements

- Ruby 3.3.0
- PostgreSQL
- Bundler
- ImageMagick, available as `magick`
- Poppler, for `pdfinfo` and `pdftoppm`
- Tesseract, for `tesseract`

On macOS, the native dependencies are typically:

```sh
brew install postgresql imagemagick poppler tesseract
```

Make sure PostgreSQL is running before preparing the database or running tests.

## Local Setup

```sh
bundle install
bin/rails db:prepare
bin/rails db:seed
bin/dev
```

Then open `http://127.0.0.1:3000`.

Useful local routes:

- `/validation` - main single-application validation flow
- `/batches/new` - batch upload flow
- `/history` - persisted validation history
- `/data-quality` - data quality view
- `/rules` - rules reference
- `/up` - Rails health check
- `/up/dependencies` - OCR/image/PDF dependency health check

## Configuration

Development and test can use `.env.local`. Do not commit environment files,
API keys, Rails credentials, or `config/master.key`.

Common variables:

- `OPENAI_API_KEY` - required for the default OpenAI validation path
- `ANTHROPIC_API_KEY` - optional, only needed for Anthropic comparison models
- `EXTRACTION_PROVIDER` - `openai` or `anthropic`; default is `openai`
- `EXTRACTION_MODEL` - default is `gpt-5.4-mini` unless overridden
- `EXTRACTION_MODE` - default is `quality`
- `EXTRACTION_EFFORT` - default is `low`
- `EXTRACTION_OCR_ENGINE` - default is `tesseract`
- `EXTRACTION_OCR_TIMEOUT_SECONDS` - default is `8`
- `EXTRACTION_OCR_REGION_REFINEMENT` - default is `false`

The model selector on the Validation page is driven by
`EXTRACTION_DEMO_MODELS`. The configured provider/model is always allowed even
when it is not listed in that menu.

## Seed Data

`bin/rails db:seed` loads real sample records from the checked-in registry and
application PDF fixtures under `db/registry` and `downloads`. Seeded samples are
used by the Validation page so a reviewer can run demos without finding their
own files.

Seeding creates records even when no model API key is present. Verification jobs
can be run later from the UI.

## Validation Workflow

Single validation can start three ways:

- choose a seeded sample
- upload an application PDF
- enter application fields and artwork manually

Batch validation supports:

- application PDFs, optionally with a manifest
- CSV rows plus matching label image files

The system persists each run as a verification attempt with the selected model,
latency, extracted evidence, findings, and final verdict. Revalidating an edited
record reuses cached extraction where possible.

## Testing And Checks

Run the Rails test suite:

```sh
bin/rails test
```

Run a secret scan before pushing public changes when `gitleaks` is available:

```sh
gitleaks detect --source . --redact --no-banner --verbose
```

Verify the production image can build:

```sh
docker build -t label-verifier-render-check .
```

The Docker image includes ImageMagick, Poppler, and Tesseract. It also creates a
small `magick` compatibility wrapper for Debian images that expose ImageMagick 6
as `convert` and `identify`.

## Render Deployment

The repository includes `render.yaml` for a Docker-based Render deployment. The
blueprint provisions:

- one Rails web service
- one persistent disk mounted at `/rails/storage` for Active Storage uploads
- separate Postgres databases for primary app data, Solid Cache, Solid Queue,
  and Solid Cable

Set these secret values in Render:

- `RAILS_MASTER_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`, only if Anthropic comparison models will be used

Render supplies these database URLs from the blueprint-managed databases:

- `DATABASE_URL`
- `CACHE_DATABASE_URL`
- `QUEUE_DATABASE_URL`
- `CABLE_DATABASE_URL`

The blueprint sets production defaults for the fast path:

- `EXTRACTION_PROVIDER=openai`
- `EXTRACTION_MODEL=gpt-5.4-nano`
- `EXTRACTION_EFFORT=low`
- `EXTRACTION_OCR_ENGINE=tesseract`
- `SOLID_QUEUE_IN_PUMA=true`
- `JOB_CONCURRENCY=1`

The Docker entrypoint validates required environment variables, runs
`bin/rails db:prepare`, and then starts Rails. Missing production secrets or
database URLs fail boot with a clear error.

## Deployment Preflight

Before pushing for deployment, this repo should pass:

```sh
bin/rails test
gitleaks detect --source . --redact --no-banner --verbose
docker build -t label-verifier-render-check .
```

The current deployment commit was verified with all three checks.
