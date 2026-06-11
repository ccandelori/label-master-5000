# frozen_string_literal: true

# The vision-extraction connector. Sends label artwork (only - never
# application data) to the model and returns LabelFacts plus the raw
# payload with bounding boxes. The one class in the system that talks to
# the API; everything else is pure.
class LabelExtractor
  Result = Extraction::ExtractorResult
  Judgment = Data.define(:same_entity, :rationale)

  PDF_CONTENT_TYPE = "application/pdf"

  def initialize(client:, config:)
    @client = client
    @config = config
  end

  def self.build
    new(client: Extraction::AnthropicClient.build, config: Rails.application.config.x.extraction)
  end

  def model_id
    @config.model
  end

  # artworks: Array of Extraction::ArtworkSource, front label first; a
  # source's 1-based position is its page.
  def extract(artworks:)
    artworks.each { |artwork| enforce_page_cap!(artwork.data) if artwork.pdf? }

    params = request_params(artworks)
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

  def request_params(artworks)
    {
      model: @config.model,
      max_tokens: @config.max_tokens,
      system_: Extraction::Schema::PROMPT,
      messages: [ {
        role: "user",
        content: artwork_blocks(artworks) +
          [ { type: "text", text: "Extract the label contents as schema-conforming JSON." } ]
      } ],
      output_config: {
        effort: @config.effort,
        format: { type: "json_schema", schema: Extraction::Schema::RESPONSE_SCHEMA }
      }.compact
    }
  end

  # A lone artwork goes unlabeled (the single-image request is unchanged);
  # a front + back pair gets the shared page labels so the model reports
  # each field's page as the image it appears on.
  def artwork_blocks(artworks)
    return [ artwork_block(artworks.first) ] if artworks.one?

    artworks.each_with_index.flat_map do |artwork, index|
      [ { type: "text", text: Extraction::Schema::PAGE_LABELS[index] }, artwork_block(artwork) ]
    end
  end

  def artwork_block(artwork)
    encoded = Base64.strict_encode64(artwork.data)
    if artwork.pdf?
      { type: "document", source: { type: "base64", media_type: PDF_CONTENT_TYPE, data: encoded } }
    else
      { type: "image", source: { type: "base64", media_type: artwork.content_type, data: encoded } }
    end
  end

  def enforce_page_cap!(data)
    pages = Extraction::PdfPages.page_count(data)
    return if pages <= @config.max_pdf_pages

    raise Extraction::PageLimitExceeded,
          "PDF has #{pages} pages; the limit is #{@config.max_pdf_pages}"
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
    Extraction::ModelResponse.parse_json(text)
  end

  def log_extraction(payload, latency)
    Rails.logger.info(JSON.generate({
      event: "label_extraction", model: @config.model, latency_ms: latency,
      legible: payload["legible"], confidence: payload["confidence"]
    }))
  end
end
