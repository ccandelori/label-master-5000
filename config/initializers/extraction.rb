# frozen_string_literal: true

# Vision-extraction configuration. Provider and model are configuration,
# not code: swap providers or tiers (or point at an agency-authorized
# endpoint) without touching the connectors.
# Anthropic default Opus 4.7: smaller tiers read label text fine but
# place bounding boxes poorly; Opus-tier vision localizes precisely
# (verified by cropping its claimed regions from real labels).
provider = ENV.fetch("EXTRACTION_PROVIDER", "anthropic")
default_model = { "anthropic" => "claude-opus-4-7", "openai" => "gpt-5.4" }.fetch(provider) do
  raise "unknown EXTRACTION_PROVIDER #{provider.inspect} (anthropic | openai)"
end
Rails.application.config.x.extraction.provider = provider
Rails.application.config.x.extraction.model = ENV.fetch("EXTRACTION_MODEL", default_model)

# Azure OpenAI (or any OpenAI-compatible endpoint): set the base URL here
# and the key in OPENAI_API_KEY; nil uses the SDK's own default. Azure
# deployments that authenticate via an api-key header can supply it
# through the SDK's OPENAI_CUSTOM_HEADERS environment variable.
Rails.application.config.x.extraction.openai_base_url = ENV["EXTRACTION_OPENAI_BASE_URL"]

# The demo model menu: pre-review checks can run under any of these to
# compare providers and tiers side by side. Each entry is provider +
# model + display label; override the whole list with compact JSON in
# EXTRACTION_DEMO_MODELS. The globally configured provider/model is
# always an allowed choice even when absent from this list.
Rails.application.config.x.extraction.demo_models = JSON.parse(
  ENV.fetch("EXTRACTION_DEMO_MODELS", <<~JSON)
    [{"provider": "anthropic", "model": "claude-opus-4-7", "label": "Claude Opus 4.7"},
     {"provider": "anthropic", "model": "claude-haiku-4-5", "label": "Claude Haiku 4.5"},
     {"provider": "openai", "model": "gpt-5.4", "label": "GPT-5.4"},
     {"provider": "openai", "model": "gpt-5.4-mini", "label": "GPT-5.4 mini"}]
  JSON
).map { |entry| entry.slice("provider", "model", "label").freeze }.freeze
Rails.application.config.x.extraction.effort = ENV.fetch("EXTRACTION_EFFORT", "low")
Rails.application.config.x.extraction.max_tokens = Integer(ENV.fetch("EXTRACTION_MAX_TOKENS", "4096"))
Rails.application.config.x.extraction.max_retries = Integer(ENV.fetch("EXTRACTION_MAX_RETRIES", "2"))
Rails.application.config.x.extraction.max_pdf_pages = Integer(ENV.fetch("EXTRACTION_MAX_PDF_PAGES", "4"))

# Below this confidence (or when the extractor reports the artwork
# illegible) verification ends as request_retake instead of issuing
# field verdicts from a bad read.
Rails.application.config.x.extraction.min_confidence = Float(ENV.fetch("EXTRACTION_MIN_CONFIDENCE", "0.5"))

# OCR bounding-box grounding (best-effort; requires the tesseract binary,
# plus pdftoppm for PDF artwork). The model decides what each field says;
# OCR re-anchors where it sits. ocr_match_threshold is the minimum fuzzy
# similarity between field text and an OCR word window for the OCR box to
# replace the model's estimate; below it the model's box is kept.
Rails.application.config.x.extraction.ocr_match_threshold = Float(ENV.fetch("EXTRACTION_OCR_MATCH_THRESHOLD", "0.8"))
Rails.application.config.x.extraction.ocr_dpi = Integer(ENV.fetch("EXTRACTION_OCR_DPI", "200"))

# OCR engine selection. "paddle" reads via the local PaddleOCR sidecar
# (ocr_service/) - far stronger on stylized, inverse, and rotated label
# type - and falls back to Tesseract automatically when the sidecar is
# unreachable. "tesseract" skips the sidecar entirely.
Rails.application.config.x.extraction.ocr_engine = ENV.fetch("EXTRACTION_OCR_ENGINE", "paddle")
Rails.application.config.x.extraction.paddle_url = ENV.fetch("EXTRACTION_PADDLE_URL", "http://127.0.0.1:8765")
Rails.application.config.x.extraction.paddle_timeout_seconds = Integer(ENV.fetch("EXTRACTION_PADDLE_TIMEOUT", "60"))
