# frozen_string_literal: true

require "test_helper"

class VlmAdjudicatorTest < ActiveSupport::TestCase
  class StubClient
    attr_reader :calls

    def initialize(responses:)
      @responses = responses
      @calls = []
    end

    def complete(params)
      @calls << params
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  class SlowStubClient
    attr_reader :calls

    def initialize(response:, sleep_seconds:)
      @response = response
      @sleep_seconds = sleep_seconds
      @calls = []
    end

    def complete(params)
      @calls << params
      sleep(@sleep_seconds)
      @response.to_json
    end
  end

  def field(name, expected)
    Extraction::VlmAdjudicator::Field.new(
      name: name,
      expected_text: expected,
      bbox_hint: nil,
      page: 1
    )
  end

  def runner(client, provider: "openai", model: "gpt-5.4-mini", max_fields: 3, timeout_seconds: 5.0)
    Extraction::VlmAdjudicator::Runner.new(
      client: client,
      provider: provider,
      model: model,
      max_fields: max_fields,
      timeout_seconds: timeout_seconds
    )
  end

  def image
    "fake-image-bytes"
  end

  test "request params use gpt mini, low-detail image input, and a compact strict schema" do
    client = StubClient.new(responses: [ { status: "absent", page: 1, reason: "not visible" }.to_json ])
    adjudicator = runner(client)

    adjudicator.adjudicate(fields: [ field("brand_name", "MIA-LOU") ], image: image, content_type: "image/png")

    params = client.calls.first
    assert_equal "gpt-5.4-mini", params[:model]
    assert_equal 300, params[:max_completion_tokens]
    image_block = params[:messages].last[:content].last
    assert_equal :image_url, image_block[:type]
    assert_equal "low", image_block[:image_url][:detail]
    assert_match(/\Adata:image\/png;base64,/, image_block[:image_url][:url])

    schema = params.dig(:response_format, :json_schema)
    assert schema[:strict]
    assert_equal %w[status page reason], schema[:schema]["required"]
    assert_nil schema[:schema].dig("properties", "bbox")
    assert_equal %w[present absent ambiguous], schema[:schema].dig("properties", "status", "enum")
  end

  test "anthropic request params use messages vision blocks and JSON-only instructions" do
    client = StubClient.new(responses: [ { status: "absent", page: 1, reason: "not visible" }.to_json ])
    adjudicator = runner(client, provider: "anthropic", model: "claude-haiku-4-5")

    adjudicator.adjudicate(fields: [ field("brand_name", "MIA-LOU") ], image: image, content_type: "image/png")

    params = client.calls.first
    assert_equal "claude-haiku-4-5", params[:model]
    assert_equal 300, params[:max_tokens]
    assert_match(/Return JSON only/, params[:system])
    assert_nil params[:response_format]
    assert_nil params[:max_completion_tokens]

    content = params.fetch(:messages).first.fetch(:content)
    text_block = content.first
    image_block = content.last
    assert_equal "text", text_block.fetch(:type)
    assert_match(/expected_value/, text_block.fetch(:text))
    assert_equal "image", image_block.fetch(:type)
    assert_equal "base64", image_block.dig(:source, :type)
    assert_equal "image/png", image_block.dig(:source, :media_type)
    assert_equal Base64.strict_encode64(image), image_block.dig(:source, :data)
  end

  test "parses a present response without requiring geometry" do
    client = StubClient.new(responses: [ { status: "present", page: 1, reason: "visible" }.to_json ])

    result = runner(client).adjudicate(
      fields: [ field("brand_name", "MIA-LOU") ],
      image: image,
      content_type: "image/png"
    ).first

    assert_equal "brand_name", result.field
    assert_equal "present", result.status
    assert_equal 1, result.page
    assert_equal "gpt-5.4-mini", result.model_id
  end

  test "fanciful name request allows split product identity presentation" do
    client = StubClient.new(responses: [ { status: "present", page: 1, reason: "visible" }.to_json ])

    runner(client).adjudicate(
      fields: [ field("fanciful_name", "GREAT BLUE BLUEBERRY BOURBON WHISKEY COCKTAIL") ],
      image: image,
      content_type: "image/png"
    )

    payload = JSON.parse(client.calls.first.fetch(:messages).last.fetch(:content).first.fetch(:text))
    assert_match(/split/i, payload.fetch("instruction"))
    assert_match(/meaningful/i, payload.fetch("instruction"))
  end

  test "demotes unsupported statuses to ambiguous" do
    client = StubClient.new(responses: [ { status: "nearby", page: 1, reason: "visible" }.to_json ])

    result = runner(client).adjudicate(
      fields: [ field("brand_name", "MIA-LOU") ],
      image: image,
      content_type: "image/png"
    ).first

    assert_equal "ambiguous", result.status
    assert_match(/Unsupported VLM status/, result.reason)
  end

  test "caps adjudication calls by max_fields" do
    client = StubClient.new(responses: 4.times.map { { status: "absent", page: 1, reason: "not visible" }.to_json })
    fields = %w[a b c d].map { |name| field(name, "value") }

    results = runner(client, max_fields: 3).adjudicate(fields: fields, image: image, content_type: "image/png")

    assert_equal %w[a b c], results.map(&:field)
    assert_equal 3, client.calls.size
  end

  test "adjudicates capped fields concurrently while preserving result order" do
    client = SlowStubClient.new(
      response: { status: "absent", page: 1, reason: "not visible" },
      sleep_seconds: 0.2
    )
    fields = %w[a b c].map { |name| field(name, "value") }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    results = runner(client, max_fields: 3).adjudicate(fields: fields, image: image, content_type: "image/png")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - started

    assert_equal %w[a b c], results.map(&:field)
    assert_equal 3, client.calls.size
    assert_operator elapsed, :<, 350
  end

  test "provider errors become ambiguous field results" do
    client = StubClient.new(responses: [ Extraction::ExtractionError.new("schema rejected") ])

    result = runner(client).adjudicate(
      fields: [ field("net_contents", "750 mL") ],
      image: image,
      content_type: "image/png"
    ).first

    assert_equal "ambiguous", result.status
    assert_match(/schema rejected/, result.reason)
  end

  test "exhausted time budget avoids provider calls" do
    client = StubClient.new(responses: [ { status: "present", page: 1, reason: "visible" }.to_json ])

    result = runner(client, timeout_seconds: -1.0).adjudicate(
      fields: [ field("brand_name", "MIA-LOU") ],
      image: image,
      content_type: "image/png"
    ).first

    assert_equal "ambiguous", result.status
    assert_match(/time budget/, result.reason)
    assert_empty client.calls
  end
end
