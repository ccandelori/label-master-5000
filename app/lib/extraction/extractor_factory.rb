# frozen_string_literal: true

module Extraction
  # Builds the configured vision extractor. Provider and model are
  # configuration, not code: EXTRACTION_PROVIDER selects the connector,
  # EXTRACTION_MODEL the model it speaks to. Every provider honors the
  # same contract (extract -> ExtractorResult, plus model_id) against the
  # same prompt and response schema, so swapping providers changes the
  # reading, never the pipeline.
  module ExtractorFactory
    module_function

    def build
      provider = Rails.application.config.x.extraction.provider
      case provider
      when "anthropic" then LabelExtractor.build
      when "openai" then OpenaiLabelExtractor.build
      else
        raise ExtractionError, "unknown EXTRACTION_PROVIDER #{provider.inspect} (anthropic | openai)"
      end
    end
  end
end
