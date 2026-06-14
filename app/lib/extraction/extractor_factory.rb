# frozen_string_literal: true

module Extraction
  # Builds the configured vision extractor. Provider and model are
  # configuration, not code: EXTRACTION_PROVIDER selects the connector,
  # EXTRACTION_MODEL the model it speaks to. Every provider honors the
  # same contract (extract -> ExtractorResult, plus model_id) against the
  # same prompt and response schema, so swapping providers changes the
  # reading, never the pipeline.
  #
  # build_for is the per-run override from the validation model menu:
  # the combo must be the configured default or one of the demo_models
  # entries - an unknown combo raises rather than silently reading with
  # something else.
  module ExtractorFactory
    module_function

    def build
      config = Rails.application.config.x.extraction
      build_for(provider: config.provider, model: config.model)
    end

    def build_for(provider:, model:)
      unless allowed?(provider, model)
        raise ExtractionError, "unknown extraction model #{provider.inspect} / #{model.inspect} " \
                               "(configure it in extraction.demo_models)"
      end

      case provider
      when "anthropic" then LabelExtractor.build(model: model)
      when "openai" then OpenaiLabelExtractor.build(model: model)
      else
        raise ExtractionError, "unknown EXTRACTION_PROVIDER #{provider.inspect} (anthropic | openai)"
      end
    end

    def allowed?(provider, model)
      config = Rails.application.config.x.extraction
      return true if provider == config.provider && model == config.model

      config.demo_models.any? { |entry| entry["provider"] == provider && entry["model"] == model }
    end
  end
end
