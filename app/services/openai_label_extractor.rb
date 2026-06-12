# frozen_string_literal: true

# The OpenAI-shaped vision-extraction connector: same contract, prompt,
# and response schema as LabelExtractor, different transport. OpenAI's
# vision input takes images only, so PDF artwork is rasterized to
# per-page PNGs (the same pdftoppm path the OCR engines use) and sent as
# one multi-image request with page labels.
class OpenaiLabelExtractor
  PDF_CONTENT_TYPE = "application/pdf"

  def initialize(client:, config:)
    @client = client
    @config = config
  end

  # model: the model id this instance speaks to; the rest of the
  # configuration is shared. A shallow copy keeps the override scoped to
  # this instance.
  def self.build(model:)
    config = Rails.application.config.x.extraction.dup
    config.model = model
    new(client: Extraction::OpenaiClient.build, config: config)
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
    payload = with_retries("label_extraction") { Extraction::ModelResponse.parse_json(@client.complete(params)) }
    latency = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started

    log_extraction(payload, latency)
    Extraction::ExtractorResult.new(
      facts: Extraction::FactsMapper.to_facts(payload),
      raw: payload,
      model_id: @config.model,
      latency_ms: latency
    )
  end

  private

  def request_params(artworks)
    {
      model: @config.model,
      max_completion_tokens: @config.max_tokens,
      messages: [
        { role: "system", content: Extraction::Schema::PROMPT },
        { role: "user", content: user_content(artworks) }
      ],
      response_format: {
        type: :json_schema,
        json_schema: {
          name: "label_extraction",
          strict: true,
          schema: Extraction::Schema::RESPONSE_SCHEMA
        }
      }
    }
  end

  def user_content(artworks)
    artwork_blocks(artworks) +
      [ { type: :text, text: "Extract the label contents as schema-conforming JSON." } ]
  end

  # A lone image goes unlabeled (the single-image request is unchanged);
  # a front + back pair gets the shared page labels. A PDF rasterizes to
  # per-page images regardless - validation guarantees a PDF never has a
  # companion back label, so the two labeling schemes cannot collide.
  def artwork_blocks(artworks)
    if artworks.one?
      artwork = artworks.first
      return artwork.pdf? ? pdf_blocks(artwork) : [ image_block(artwork.data, artwork.content_type) ]
    end

    artworks.each_with_index.flat_map do |artwork, index|
      [ { type: :text, text: Extraction::Schema::PAGE_LABELS[index] },
        image_block(artwork.data, artwork.content_type) ]
    end
  end

  def pdf_blocks(artwork)
    Extraction::PdfPages.rasterize(data: artwork.data, dpi: @config.ocr_dpi, pdftoppm: "pdftoppm") do |pages|
      pages.flat_map do |path, number|
        [ { type: :text, text: "PDF page #{number}:" }, image_block(File.binread(path), "image/png") ]
      end
    end
  end

  def image_block(bytes, media_type)
    { type: :image_url, image_url: { url: "data:#{media_type};base64,#{Base64.strict_encode64(bytes)}" } }
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
    rescue Extraction::ResponseParseError, OpenAI::Errors::APIError => e
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

  def log_extraction(payload, latency)
    Rails.logger.info(JSON.generate({
      event: "label_extraction", model: @config.model, latency_ms: latency,
      legible: payload["legible"], confidence: payload["confidence"]
    }))
  end
end
