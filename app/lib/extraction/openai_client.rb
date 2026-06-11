# frozen_string_literal: true

module Extraction
  # Thin adapter over the official OpenAI SDK, the OpenAI counterpart to
  # AnthropicClient: request hashes in, response text out. base_url makes
  # the endpoint deployment configuration (an Azure OpenAI or other
  # OpenAI-compatible endpoint) rather than code; nil falls through to
  # the SDK's own default resolution.
  class OpenaiClient
    def initialize(sdk_client:)
      @sdk_client = sdk_client
    end

    def self.build
      new(sdk_client: OpenAI::Client.new(
        api_key: ENV["OPENAI_API_KEY"],
        base_url: Rails.application.config.x.extraction.openai_base_url
      ))
    end

    # params is the Chat Completions request body as a hash. Returns the
    # first choice's message content.
    def complete(params)
      response = @sdk_client.chat.completions.create(**params)
      message = response.choices.first&.message
      if message&.refusal.present?
        raise ResponseParseError, "model refused: #{message.refusal.to_s.first(200)}"
      end

      content = message&.content
      raise ResponseParseError, "response contained no message content" if content.blank?

      content
    end
  end
end
