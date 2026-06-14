# frozen_string_literal: true

# Label-extraction configuration. Quality mode is the production default:
# local Tesseract OCR first, VLM fallback only when OCR cannot produce
# acceptable findings.
provider = ENV.fetch("EXTRACTION_PROVIDER", "openai")
default_model = { "anthropic" => "claude-haiku-4-5", "openai" => "gpt-5.4-mini" }.fetch(provider) do
  raise "unknown EXTRACTION_PROVIDER #{provider.inspect} (anthropic | openai)"
end
Rails.application.config.x.extraction.provider = provider
Rails.application.config.x.extraction.model = ENV.fetch("EXTRACTION_MODEL", default_model)
Rails.application.config.x.extraction.mode = ENV.fetch("EXTRACTION_MODE", "quality")

# Azure OpenAI (or any OpenAI-compatible endpoint): set the base URL here
# and the key in OPENAI_API_KEY; nil uses the SDK's own default. Azure
# deployments that authenticate via an api-key header can supply it
# through the SDK's OPENAI_CUSTOM_HEADERS environment variable.
Rails.application.config.x.extraction.openai_base_url = ENV["EXTRACTION_OPENAI_BASE_URL"]

# The validation model menu can run under any of these to
# compare providers and tiers side by side. Each entry is provider +
# model + display label; override the whole list with compact JSON in
# EXTRACTION_DEMO_MODELS. The globally configured provider/model is
# always an allowed choice even when absent from this list.
Rails.application.config.x.extraction.demo_models = JSON.parse(
  ENV.fetch("EXTRACTION_DEMO_MODELS", <<~JSON)
    [{"provider": "openai", "model": "gpt-5.4-nano", "label": "GPT-5.4 nano"},
     {"provider": "openai", "model": "gpt-5.4-mini", "label": "GPT-5.4 mini"},
     {"provider": "openai", "model": "gpt-5.4", "label": "GPT-5.4"},
     {"provider": "anthropic", "model": "claude-haiku-4-5", "label": "Claude Haiku 4.5"}]
  JSON
).map { |entry| entry.slice("provider", "model", "label").freeze }.freeze
Rails.application.config.x.extraction.effort = ENV.fetch("EXTRACTION_EFFORT", "low")
Rails.application.config.x.extraction.max_tokens = Integer(ENV.fetch("EXTRACTION_MAX_TOKENS", "4096"))
Rails.application.config.x.extraction.max_retries = Integer(ENV.fetch("EXTRACTION_MAX_RETRIES", "2"))
Rails.application.config.x.extraction.max_pdf_pages = Integer(ENV.fetch("EXTRACTION_MAX_PDF_PAGES", "4"))
Rails.application.config.x.extraction.vlm_adjudication_model =
  ENV.fetch("EXTRACTION_VLM_ADJUDICATION_MODEL", "gpt-5.4-mini")
Rails.application.config.x.extraction.vlm_adjudication_max_fields =
  Integer(ENV.fetch("EXTRACTION_VLM_ADJUDICATION_MAX_FIELDS", "6"))
Rails.application.config.x.extraction.vlm_adjudication_timeout_seconds =
  Float(ENV.fetch("EXTRACTION_VLM_ADJUDICATION_TIMEOUT_SECONDS", "5"))

# Below this confidence (or when the extractor reports the artwork
# illegible) verification ends as request_retake instead of issuing
# field verdicts from a bad read.
Rails.application.config.x.extraction.min_confidence = Float(ENV.fetch("EXTRACTION_MIN_CONFIDENCE", "0.5"))

Rails.application.config.x.extraction.ocr_match_threshold = 0.8
Rails.application.config.x.extraction.ocr_dpi = 200
Rails.application.config.x.extraction.ocr_timeout_seconds = Float(ENV.fetch("EXTRACTION_OCR_TIMEOUT_SECONDS", "8"))
Rails.application.config.x.extraction.ocr_engine = ENV.fetch("EXTRACTION_OCR_ENGINE", "tesseract")
Rails.application.config.x.extraction.ocr_region_refinement =
  ENV.fetch("EXTRACTION_OCR_REGION_REFINEMENT", "false") == "true"
Rails.application.config.x.extraction.paddle_url = ENV.fetch("EXTRACTION_PADDLE_URL", "http://127.0.0.1:8765")
Rails.application.config.x.extraction.paddle_timeout_seconds =
  Float(ENV.fetch("EXTRACTION_PADDLE_TIMEOUT_SECONDS", "20"))
Rails.application.config.x.extraction.ocr_auto_start =
  ENV.fetch("EXTRACTION_OCR_AUTO_START", "true") == "true"
Rails.application.config.x.extraction.ocr_start_timeout_seconds =
  Float(ENV.fetch("EXTRACTION_OCR_START_TIMEOUT_SECONDS", "8"))
Rails.application.config.x.extraction.ocr_start_command =
  ENV.fetch("EXTRACTION_OCR_START_COMMAND", "ocr_service/bin/serve")
Rails.application.config.x.extraction.ocr_service_pidfile =
  ENV.fetch("EXTRACTION_OCR_SERVICE_PIDFILE", Rails.root.join("tmp/pids/ocr_service.pid").to_s)
Rails.application.config.x.extraction.ocr_service_log =
  ENV.fetch("EXTRACTION_OCR_SERVICE_LOG", Rails.root.join("log/ocr_service.log").to_s)
