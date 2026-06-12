# frozen_string_literal: true

require "test_helper"

class ExtractorFactoryTest < ActiveSupport::TestCase
  def with_provider(provider)
    config = Rails.application.config.x.extraction
    original = config.provider
    config.provider = provider
    yield
  ensure
    config.provider = original
  end

  test "builds the Anthropic extractor by default configuration" do
    with_provider("anthropic") do
      assert_instance_of LabelExtractor, Extraction::ExtractorFactory.build
    end
  end

  test "builds the OpenAI extractor when configured" do
    with_provider("openai") do
      original_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key"
      assert_instance_of OpenaiLabelExtractor, Extraction::ExtractorFactory.build
    ensure
      ENV["OPENAI_API_KEY"] = original_key
    end
  end

  test "an unknown provider raises instead of silently defaulting" do
    with_provider("watson") do
      error = assert_raises(Extraction::ExtractionError) { Extraction::ExtractorFactory.build }
      assert_match(/watson/, error.message)
    end
  end

  test "build_for overrides the model for a demo-menu combo" do
    extractor = Extraction::ExtractorFactory.build_for(provider: "anthropic", model: "claude-haiku-4-5")

    assert_instance_of LabelExtractor, extractor
    assert_equal "claude-haiku-4-5", extractor.model_id
    assert_equal Rails.application.config.x.extraction.model,
                 Extraction::ExtractorFactory.build.model_id,
                 "the override must not leak into the global configuration"
  end

  test "build_for raises for a combo outside the menu and the configured default" do
    error = assert_raises(Extraction::ExtractionError) do
      Extraction::ExtractorFactory.build_for(provider: "openai", model: "made-up-model")
    end
    assert_match(/made-up-model/, error.message)
  end
end
