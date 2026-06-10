# frozen_string_literal: true

module Extraction
  # Thin adapter over the official Anthropic SDK. The single seam between
  # this application and the vision API: everything above it deals in plain
  # request hashes and response text, which keeps the extractor testable
  # against a stub and makes the endpoint swappable (e.g. a FedRAMP
  # GovCloud deployment) without touching extraction logic.
  class AnthropicClient
    def initialize(sdk_client:)
      @sdk_client = sdk_client
    end

    def self.build
      new(sdk_client: Anthropic::Client.new)
    end

    # params is the Messages API request body as a hash. Returns the
    # response's first text block.
    def complete(params)
      response = @sdk_client.messages.create(**params)
      block = response.content.find { |b| b.type.to_s == "text" }
      raise ResponseParseError, "response contained no text block" if block.nil?

      block.text
    end
  end
end
