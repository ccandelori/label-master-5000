# frozen_string_literal: true

require "test_helper"

class LabelExtractorTest < ActiveSupport::TestCase
  Config = Struct.new(:model, :effort, :max_tokens, :max_retries, :max_pdf_pages, keyword_init: true)

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

  def config
    Config.new(model: "claude-opus-4-7", effort: "low", max_tokens: 4096, max_retries: 2, max_pdf_pages: 4)
  end

  def source(data, content_type)
    Extraction::ArtworkSource.new(data: data, content_type: content_type, checksum: "test-checksum")
  end

  def payload_json
    {
      "legible" => true,
      "confidence" => 0.94,
      "fields" => {
        "brand_name" => { "text" => "OLD TOM DISTILLERY", "bbox" => [ 120, 80, 400, 60 ], "page" => 1, "confidence" => 0.98 },
        "fanciful_name" => nil,
        "class_type_designation" => { "text" => "Kentucky Straight Bourbon Whiskey", "bbox" => [ 140, 160, 360, 30 ], "page" => 1, "confidence" => 0.97 },
        "alcohol_statement" => { "text" => "45% ALC./VOL. (90 PROOF)", "bbox" => [ 180, 220, 260, 24 ], "page" => 1, "confidence" => 0.96 },
        "net_contents" => { "text" => "750 mL", "bbox" => [ 250, 600, 100, 22 ], "page" => 1, "confidence" => 0.99 },
        "name_address_statement" => { "text" => "DISTILLED AND BOTTLED BY OLD TOM DISTILLING CO., BARDSTOWN, KY", "bbox" => [ 90, 640, 460, 20 ], "page" => 1, "confidence" => 0.92 },
        "country_of_origin_statement" => nil,
        "government_warning" => { "text" => "GOVERNMENT WARNING: ...", "bbox" => [ 60, 700, 520, 80 ], "page" => 1, "confidence" => 0.91 },
        "commodity_statement" => nil,
        "appellation" => nil,
        "vintage" => { "text" => "2021", "bbox" => [ 300, 130, 60, 20 ], "page" => 1, "confidence" => 0.9 }
      },
      "varietals" => [ { "text" => "Merlot", "bbox" => [ 1, 2, 3, 4 ], "page" => 1, "confidence" => 0.9 } ],
      "disclosures" => [ { "text" => "CONTAINS SULFITES", "bbox" => [ 5, 6, 7, 8 ], "page" => 1, "confidence" => 0.95 } ],
      "warning_attributes" => { "prefix_all_caps" => true, "prefix_bold" => nil, "continuous_paragraph" => true }
    }.to_json
  end

  test "an effort-capable model sends the configured effort" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    extractor.extract(artworks: [ source("fake-png-bytes", "image/png") ])

    assert_equal "low", client.calls.first.dig(:output_config, :effort)
  end

  test "a model without effort support gets the identical request minus the effort key" do
    haiku = Config.new(model: "claude-haiku-4-5", effort: "low", max_tokens: 4096, max_retries: 2, max_pdf_pages: 4)
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: haiku)
    extractor.extract(artworks: [ source("fake-png-bytes", "image/png") ])

    params = client.calls.first
    assert_not params[:output_config].key?(:effort), "effort must not be sent to a model that rejects it"
    assert_equal "json_schema", params.dig(:output_config, :format, :type)
    assert_equal "claude-haiku-4-5", params[:model]
  end

  test "image extraction sends an image block and the schema" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    extractor.extract(artworks: [ source("fake-png-bytes", "image/png") ])

    params = client.calls.first
    block = params[:messages].first[:content].first
    assert_equal "image", block[:type]
    assert_equal "image/png", block[:source][:media_type]
    assert_equal "fake-png-bytes", Base64.strict_decode64(block[:source][:data])
    assert_equal "json_schema", params.dig(:output_config, :format, :type)
    assert_equal Extraction::Schema::RESPONSE_SCHEMA, params.dig(:output_config, :format, :schema)
    assert_equal "claude-opus-4-7", params[:model]
  end

  test "a front and back pair sends both images with shared page labels" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    extractor.extract(artworks: [ source("front-bytes", "image/png"), source("back-bytes", "image/jpeg") ])

    content = client.calls.first[:messages].first[:content]
    assert_equal Extraction::Schema::PAGE_LABELS[0], content[0][:text]
    assert_equal "image", content[1][:type]
    assert_equal "front-bytes", Base64.strict_decode64(content[1][:source][:data])
    assert_equal Extraction::Schema::PAGE_LABELS[1], content[2][:text]
    assert_equal "back-bytes", Base64.strict_decode64(content[3][:source][:data])
  end

  test "PDF extraction sends a native document block" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    extractor.extract(artworks: [ source("%PDF-1.4 /Type /Page >>", "application/pdf") ])

    block = client.calls.first[:messages].first[:content].first
    assert_equal "document", block[:type]
    assert_equal "application/pdf", block[:source][:media_type]
  end

  test "PDFs over the page cap are rejected before any API call" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    five_pages = "%PDF-1.4 " + ("/Type /Page >> " * 5)

    assert_raises(Extraction::PageLimitExceeded) do
      extractor.extract(artworks: [ source(five_pages, "application/pdf") ])
    end
    assert_empty client.calls
  end

  test "the artwork is the only application data that leaves" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    extractor.extract(artworks: [ source("bytes", "image/png") ])

    serialized = JSON.generate(client.calls.first.except(:messages))
    text_parts = client.calls.first[:messages].flat_map { |m| Array(m[:content]) }
                       .select { |c| c.is_a?(Hash) && c[:type] == "text" }
    assert_equal 1, text_parts.size
    assert_no_match(/OLD TOM|Bardstown|26-1042/, serialized)
  end

  test "successful extraction maps facts, keeps raw boxes, records latency" do
    client = StubClient.new(responses: [ payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    result = extractor.extract(artworks: [ source("bytes", "image/png") ])

    assert_equal "OLD TOM DISTILLERY", result.facts.brand_name
    assert_equal 2021, result.facts.vintage_year
    assert_equal [ "Merlot" ], result.facts.varietals
    assert_equal [ "CONTAINS SULFITES" ], result.facts.disclosures
    assert_nil result.facts.warning_prefix_bold
    assert result.facts.warning_continuous_paragraph
    assert_equal [ 120, 80, 400, 60 ], result.raw.dig("fields", "brand_name", "bbox")
    assert_equal "claude-opus-4-7", result.model_id
    assert result.latency_ms >= 0
  end

  test "code fences around the JSON are tolerated" do
    client = StubClient.new(responses: [ "```json\n#{payload_json}\n```" ])
    extractor = LabelExtractor.new(client: client, config: config)
    result = extractor.extract(artworks: [ source("bytes", "image/png") ])
    assert_equal "OLD TOM DISTILLERY", result.facts.brand_name
  end

  test "malformed responses retry then raise a typed error" do
    client = StubClient.new(responses: [ "not json", "still not json", "nope" ])
    extractor = LabelExtractor.new(client: client, config: config)

    assert_raises(Extraction::ResponseParseError) do
      extractor.extract(artworks: [ source("bytes", "image/png") ])
    end
    assert_equal 3, client.calls.size
  end

  test "a retry that succeeds recovers" do
    client = StubClient.new(responses: [ "not json", payload_json ])
    extractor = LabelExtractor.new(client: client, config: config)
    result = extractor.extract(artworks: [ source("bytes", "image/png") ])
    assert_equal "OLD TOM DISTILLERY", result.facts.brand_name
    assert_equal 2, client.calls.size
  end

  test "illegible extraction passes the flag through" do
    payload = JSON.parse(payload_json)
    payload["legible"] = false
    payload["confidence"] = 0.2
    client = StubClient.new(responses: [ payload.to_json ])
    extractor = LabelExtractor.new(client: client, config: config)

    result = extractor.extract(artworks: [ source("bytes", "image/png") ])
    assert_not result.facts.legible
    assert_in_delta 0.2, result.facts.confidence, 0.001
  end

  test "judge_equivalence sends only the two strings" do
    client = StubClient.new(responses: [ '{"same_entity": true, "rationale": "Same name reordered"}' ])
    extractor = LabelExtractor.new(client: client, config: config)

    judgment = extractor.judge_equivalence(expected: "Old Tom Distilling Co.", extracted: "OLD TOM DISTILLING COMPANY")
    assert judgment.same_entity
    assert_match(/reordered/, judgment.rationale)

    content = client.calls.first[:messages].first[:content]
    assert_equal({ "left" => "Old Tom Distilling Co.", "right" => "OLD TOM DISTILLING COMPANY" }, JSON.parse(content))
  end
end
