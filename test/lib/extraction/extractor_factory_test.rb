# frozen_string_literal: true

require "test_helper"

class ExtractorFactoryTest < ActiveSupport::TestCase
  def with_extraction_config(provider:, model:)
    config = Rails.application.config.x.extraction
    original_provider = config.provider
    original_model = config.model
    config.provider = provider
    config.model = model
    yield
  ensure
    config.provider = original_provider
    config.model = original_model
  end

  def with_openai_key
    original_key = ENV["OPENAI_API_KEY"]
    ENV["OPENAI_API_KEY"] = "test-key"
    yield
  ensure
    ENV["OPENAI_API_KEY"] = original_key
  end

  test "builds the OpenAI mini extractor by default configuration" do
    with_openai_key do
      extractor = Extraction::ExtractorFactory.build
      assert_instance_of OpenaiLabelExtractor, extractor
      assert_equal "gpt-5.4-mini", extractor.model_id
    end
  end

  test "builds the Anthropic extractor when configured" do
    with_extraction_config(provider: "anthropic", model: "claude-haiku-4-5") do
      assert_instance_of LabelExtractor, Extraction::ExtractorFactory.build
    end
  end

  test "builds the OpenAI extractor when configured" do
    with_extraction_config(provider: "openai", model: "gpt-5.4-mini") do
      with_openai_key do
        assert_instance_of OpenaiLabelExtractor, Extraction::ExtractorFactory.build
      end
    end
  end

  test "an unknown provider raises instead of silently defaulting" do
    with_extraction_config(provider: "watson", model: "watson-label-reader") do
      error = assert_raises(Extraction::ExtractionError) { Extraction::ExtractorFactory.build }
      assert_match(/watson/, error.message)
    end
  end

  test "build_for overrides the model for a demo-menu combo" do
    extractor = Extraction::ExtractorFactory.build_for(provider: "anthropic", model: "claude-haiku-4-5")

    assert_instance_of LabelExtractor, extractor
    assert_equal "claude-haiku-4-5", extractor.model_id
    with_openai_key do
      assert_equal Rails.application.config.x.extraction.model,
                   Extraction::ExtractorFactory.build.model_id,
                   "the override must not leak into the global configuration"
    end
  end

  test "build_for raises for a combo outside the menu and the configured default" do
    error = assert_raises(Extraction::ExtractionError) do
      Extraction::ExtractorFactory.build_for(provider: "openai", model: "made-up-model")
    end
    assert_match(/made-up-model/, error.message)
  end
end
