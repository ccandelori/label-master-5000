# frozen_string_literal: true

require "test_helper"

class OpenaiLabelExtractorTest < ActiveSupport::TestCase
  Config = Struct.new(:model, :max_tokens, :max_retries, :max_pdf_pages, :ocr_dpi, keyword_init: true)

  class StubClient
    attr_reader :calls

    def initialize(responses:)
      @responses = responses
      @calls = []
    end

    def complete(params)
      @calls << params
      response = @responses[[ @calls.size - 1, @responses.size - 1 ].min]
      raise response if response.is_a?(Exception)

      response
    end
  end

  # A minimal single-page PDF that pdftoppm can rasterize.
  MINIMAL_PDF = <<~PDF
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] >> endobj
    trailer << /Root 1 0 R >>
  PDF

  def config
    Config.new(model: "gpt-5.4-mini", max_tokens: 4096, max_retries: 2, max_pdf_pages: 4, ocr_dpi: 72)
  end

  def source(data, content_type)
    Extraction::ArtworkSource.new(data: data, content_type: content_type, checksum: "test-checksum")
  end

  def payload_json
    {
      "legible" => true,
      "confidence" => 0.9,
      "image_width" => 800,
      "image_height" => 600,
      "fields" => Extraction::Schema::FIELD_KEYS.index_with { nil },
      "varietals" => [],
      "disclosures" => [],
      "warning_attributes" => { "prefix_all_caps" => nil, "prefix_bold" => nil, "continuous_paragraph" => nil }
    }.to_json
  end

  test "image extraction sends a data-url image block, the shared prompt, and the strict schema" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = OpenaiLabelExtractor.new(client: client, config: config)
    result = extractor.extract(artworks: [ source("fake-png-bytes", "image/png") ], application: nil)

    params = client.calls.first
    assert_equal "gpt-5.4-mini", params[:model]
    assert_equal Extraction::Schema::PROMPT, params[:messages].first[:content]

    image = params[:messages].last[:content].first
    assert_equal :image_url, image[:type]
    assert_equal "data:image/png;base64,#{Base64.strict_encode64('fake-png-bytes')}", image[:image_url][:url]

    schema = params.dig(:response_format, :json_schema)
    assert schema[:strict]
    assert_equal Extraction::Schema::RESPONSE_SCHEMA, schema[:schema]

    assert_equal "gpt-5.4-mini", result.model_id
    assert result.raw["legible"]
  end

  test "grounded extraction sends application search targets in the user message" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = OpenaiLabelExtractor.new(client: client, config: config)
    application = LabelApplication.new(
      serial_number: "26-1042",
      brand_name: "MIA-LOU",
      alcohol_content: 13.5,
      net_contents: "750 mL",
      applicant_name_address: "Credo Properties LLC, Mechanicsburg, PA"
    )

    extractor.extract(artworks: [ source("fake-png-bytes", "image/png") ], application: application)

    prompt = client.calls.first[:messages].last[:content].last[:text]
    assert_match(/application_search_targets/, prompt)
    assert_match(/MIA-LOU/, prompt)
    assert_match(/13\.5% ALC\/VOL/, prompt)
    assert_match(/regulatory_evidence_fields/, prompt)
    assert_match(/proof-only/, prompt)
    assert_no_match(/26-1042/, prompt)
    schema = client.calls.first.dig(:response_format, :json_schema, :schema)
    assert_includes schema["required"], "regulatory_evidence"
    assert_includes schema.dig("properties", "regulatory_evidence", "required"), "alcohol_statement"
  end

  test "PDF extraction rasterizes pages into labeled image blocks" do
    skip "pdftoppm not available" unless system("which pdftoppm > /dev/null 2>&1")

    client = StubClient.new(responses: [ payload_json ])
    extractor = OpenaiLabelExtractor.new(client: client, config: config)
    extractor.extract(artworks: [ source(MINIMAL_PDF, "application/pdf") ], application: nil)

    content = client.calls.first[:messages].last[:content]
    assert_equal({ type: :text, text: "PDF page 1:" }, content.first)
    assert_equal :image_url, content.second[:type]
    assert_match(/\Adata:image\/png;base64,/, content.second[:image_url][:url])
  end

  test "PDFs over the page cap are rejected before any API call" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = OpenaiLabelExtractor.new(client: client, config: config)
    five_pages = "%PDF-1.4 " + ("/Type /Page >> " * 5)

    assert_raises(Extraction::PageLimitExceeded) do
      extractor.extract(artworks: [ source(five_pages, "application/pdf") ], application: nil)
    end
    assert_empty client.calls
  end

  test "retries transient API errors, then succeeds" do
    client = StubClient.new(responses: [
      OpenAI::Errors::APIConnectionError.new(url: "https://api.openai.com/v1"),
      payload_json
    ])
    extractor = OpenaiLabelExtractor.new(client: client, config: config)

    result = extractor.extract(artworks: [ source("bytes", "image/png") ], application: nil)
    assert_equal 2, client.calls.size
    assert result.raw["legible"]
  end

  test "a persistently malformed response raises ExtractionError after retries" do
    client = StubClient.new(responses: [ "not json at all" ])
    extractor = OpenaiLabelExtractor.new(client: client, config: config)

    assert_raises(Extraction::ResponseParseError) do
      extractor.extract(artworks: [ source("bytes", "image/png") ], application: nil)
    end
    assert_equal 3, client.calls.size, "initial attempt plus max_retries"
  end
end
