# LabelMaster 5000

Rails application for validating TTB/COLA application records against submitted
label artwork.

## Runtime dependencies

The app shells out to native tools during PDF/image/OCR processing:

- ImageMagick (`magick`)
- Poppler (`pdfinfo`, `pdftoppm`)
- Tesseract (`tesseract`)

The production Docker image installs those packages. Local development machines
need them on `PATH` for PDF upload and OCR tests to run without skips.

## Render deployment

The repository includes `render.yaml` for a Docker-based Render deployment. The
blueprint provisions:

- one Rails web service
- one persistent disk mounted at `/rails/storage` for Active Storage uploads
- separate Postgres databases for primary app data, Solid Cache, Solid Queue,
  and Solid Cable

Set these secret values in Render. They are intentionally not committed:

- `RAILS_MASTER_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`, only if Anthropic comparison models will be used

The blueprint sets non-secret defaults for the fast validation path: OpenAI,
`gpt-5.4-nano`, low effort, local Tesseract OCR, and Solid Queue running inside
Puma. Change those environment variables in Render when comparing models.

The Docker entrypoint runs `bin/rails db:prepare` before starting the server.
