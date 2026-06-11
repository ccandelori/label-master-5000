# frozen_string_literal: true

module Extraction
  # Response-text handling shared by the provider connectors: models
  # occasionally wrap structured output in markdown fences despite
  # instructions, and a fenced or malformed body must surface as a
  # ResponseParseError (retriable) rather than a JSON exception.
  module ModelResponse
    module_function

    def parse_json(text)
      JSON.parse(strip_fences(text))
    rescue JSON::ParserError => e
      raise ResponseParseError, "model response was not valid JSON: #{e.message}"
    end

    def strip_fences(text)
      text.to_s.sub(/\A\s*```(?:json)?\s*/, "").sub(/\s*```\s*\z/, "")
    end
  end
end
