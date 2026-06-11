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
end
