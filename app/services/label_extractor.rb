# frozen_string_literal: true

# The vision-extraction connector. Sends label artwork (only - never
# application data) to the model and returns LabelFacts plus the raw
# payload with bounding boxes. The one class in the system that talks to
# the API; everything else is pure.
class LabelExtractor
  Result = Data.define(:facts, :raw, :model_id, :latency_ms)
  Judgment = Data.define(:same_entity, :rationale)

  PDF_CONTENT_TYPE = "application/pdf"

  def initialize(client:, config:)
    @client = client
    @config = config
  end

  def self.build
    new(client: Extraction::AnthropicClient.build, config: Rails.application.config.x.extraction)
  end

  # data: raw artwork bytes; content_type: one of the allowed upload types.
  def extract(data:, content_type:)
    enforce_page_cap!(data) if content_type == PDF_CONTENT_TYPE

    params = request_params(data, content_type)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    payload = with_retries("label_extraction") { parse_json(@client.complete(params)) }
    latency = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started

    log_extraction(payload, latency)
    Result.new(
      facts: Extraction::FactsMapper.to_facts(payload),
      raw: payload,
      model_id: @config.model,
      latency_ms: latency
    )
  end

  # Egress-minimal equivalence judgment: only the two strings leave the
  # system, no surrounding application context.
  def judge_equivalence(expected:, extracted:)
    params = {
      model: @config.model,
      max_tokens: 256,
      system_: Extraction::Schema::MATCH_JUDGMENT_PROMPT,
      messages: [ {
        role: "user",
        content: JSON.generate({ "left" => expected, "right" => extracted })
      } ]
    }

    payload = with_retries("match_judgment") { parse_json(@client.complete(params)) }
    Judgment.new(same_entity: !!payload["same_entity"], rationale: payload["rationale"].to_s)
  end

  private

  def request_params(data, content_type)
    {
      model: @config.model,
      max_tokens: @config.max_tokens,
      system_: Extraction::Schema::PROMPT,
      messages: [ {
        role: "user",
        content: [
          artwork_block(data, content_type),
          { type: "text", text: "Extract the label contents as schema-conforming JSON." }
        ]
      } ],
      output_config: {
        effort: @config.effort,
        format: { type: "json_schema", schema: Extraction::Schema::RESPONSE_SCHEMA }
      }.compact
    }
  end

  def artwork_block(data, content_type)
    encoded = Base64.strict_encode64(data)
    if content_type == PDF_CONTENT_TYPE
      { type: "document", source: { type: "base64", media_type: PDF_CONTENT_TYPE, data: encoded } }
    else
      { type: "image", source: { type: "base64", media_type: content_type, data: encoded } }
    end
  end

  def enforce_page_cap!(data)
    pages = pdf_page_count(data)
    return if pages <= @config.max_pdf_pages

    raise Extraction::PageLimitExceeded,
          "PDF has #{pages} pages; the limit is #{@config.max_pdf_pages}"
  end

  # Page-object count from the raw bytes. Crude but dependency-free; the
  # cap exists to protect the latency budget, not for exactness.
  def pdf_page_count(data)
    count = data.scan(%r{/Type\s*/Page[^s]}).size
    count.positive? ? count : 1
  end

  def with_retries(operation)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue Extraction::ResponseParseError, Anthropic::Errors::APIError => e
      if attempts <= @config.max_retries
        Rails.logger.warn(JSON.generate({
          event: "extraction_retry", operation: operation, attempt: attempts,
          error_class: e.class.name, error: e.message.to_s.first(200)
        }))
        retry
      end
      raise wrap_error(e)
    end
  end

  def wrap_error(error)
    return error if error.is_a?(Extraction::ExtractionError)

    Extraction::ExtractionError.new("#{error.class.name}: #{error.message}")
  end

  def parse_json(text)
    JSON.parse(strip_fences(text))
  rescue JSON::ParserError => e
    raise Extraction::ResponseParseError, "model response was not valid JSON: #{e.message}"
  end

  def strip_fences(text)
    text.to_s.sub(/\A\s*```(?:json)?\s*/, "").sub(/\s*```\s*\z/, "")
  end

  def log_extraction(payload, latency)
    Rails.logger.info(JSON.generate({
      event: "label_extraction", model: @config.model, latency_ms: latency,
      legible: payload["legible"], confidence: payload["confidence"]
    }))
  end
end
