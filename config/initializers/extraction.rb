# frozen_string_literal: true

# Vision-extraction configuration. The model is configuration, not code:
# swap tiers (or point at an agency-authorized endpoint) without touching
# the connector.
Rails.application.config.x.extraction.model = ENV.fetch("EXTRACTION_MODEL", "claude-haiku-4-5")
Rails.application.config.x.extraction.max_tokens = Integer(ENV.fetch("EXTRACTION_MAX_TOKENS", "4096"))
Rails.application.config.x.extraction.max_retries = Integer(ENV.fetch("EXTRACTION_MAX_RETRIES", "2"))
Rails.application.config.x.extraction.max_pdf_pages = Integer(ENV.fetch("EXTRACTION_MAX_PDF_PAGES", "4"))

# Below this confidence (or when the extractor reports the artwork
# illegible) verification ends as request_retake instead of issuing
# field verdicts from a bad read.
Rails.application.config.x.extraction.min_confidence = Float(ENV.fetch("EXTRACTION_MIN_CONFIDENCE", "0.5"))
