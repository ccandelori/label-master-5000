# frozen_string_literal: true

require "base64"
require "json"

module Extraction
  # Focused VLM adjudication for fields OCR could not settle. The model
  # classifies presence only; it does not become a source of observed text.
  module VlmAdjudicator
    Field = Data.define(:name, :expected_text, :bbox_hint, :page)
    Result = Data.define(:field, :status, :page, :reason, :model_id)

    STATUSES = %w[present absent ambiguous].freeze
    PROVIDERS = %w[openai anthropic].freeze

    module_function

    def build
      config = Rails.application.config.x.extraction
      build_for(provider: nil, model: config.vlm_adjudication_model)
    end

    def build_for(provider:, model:)
      config = Rails.application.config.x.extraction
      resolved_model = model.presence || config.vlm_adjudication_model.presence || config.model
      resolved_provider = provider.presence || provider_for_model(config: config, model: resolved_model) || config.provider
      unless PROVIDERS.include?(resolved_provider)
        raise ExtractionError, "unknown VLM adjudication provider #{resolved_provider.inspect} (#{PROVIDERS.join(' | ')})"
      end

      Runner.new(
        client: client_for_provider(resolved_provider),
        provider: resolved_provider,
        model: resolved_model,
        max_fields: config.vlm_adjudication_max_fields,
        timeout_seconds: config.vlm_adjudication_timeout_seconds
      )
    end

    def provider_for_model(config:, model:)
      Array(config.demo_models).find { |entry| entry["model"] == model }&.fetch("provider", nil)
    end

    def client_for_provider(provider)
      case provider
      when "openai" then OpenaiClient.build
      when "anthropic" then AnthropicClient.build
      else
        raise ExtractionError, "unknown VLM adjudication provider #{provider.inspect} (#{PROVIDERS.join(' | ')})"
      end
    end

    class Runner
      def initialize(client:, provider:, model:, max_fields:, timeout_seconds:)
        @client = client
        @provider = provider
        @model = model
        @max_fields = max_fields
        @timeout_seconds = timeout_seconds
      end

      def adjudicate(fields:, image:, content_type:)
        deadline = monotonic_ms + (@timeout_seconds * 1000.0)
        fields.first(@max_fields).map do |field|
          run_async do
            if monotonic_ms >= deadline
              ambiguous_result(field: field, reason: "VLM adjudication time budget exhausted")
            else
              adjudicate_field(field: field, image: image, content_type: content_type)
            end
          end
        end.map(&:value)
      end

      def request_params(field:, image:, content_type:)
        case @provider
        when "openai"
          openai_request_params(field: field, image: image, content_type: content_type)
        when "anthropic"
          anthropic_request_params(field: field, image: image, content_type: content_type)
        else
          raise ExtractionError, "unknown VLM adjudication provider #{@provider.inspect} (#{PROVIDERS.join(' | ')})"
        end
      end

      private

      def openai_request_params(field:, image:, content_type:)
        {
          model: @model,
          max_completion_tokens: 300,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: user_content(field: field, image: image, content_type: content_type) }
          ],
          response_format: {
            type: :json_schema,
            json_schema: {
              name: "field_adjudication",
              strict: true,
              schema: response_schema
            }
          }
        }
      end

      def anthropic_request_params(field:, image:, content_type:)
        {
          model: @model,
          max_tokens: 300,
          system: anthropic_system_prompt,
          messages: [
            {
              role: "user",
              content: anthropic_user_content(field: field, image: image, content_type: content_type)
            }
          ]
        }
      end

      def adjudicate_field(field:, image:, content_type:)
        params = request_params(field: field, image: image, content_type: content_type)
        payload = ModelResponse.parse_json(@client.complete(params))
        result_from_payload(field: field, payload: payload)
      rescue ResponseParseError, ExtractionError => e
        ambiguous_result(field: field, reason: "#{e.class.name}: #{e.message.to_s.first(200)}")
      rescue StandardError => e
        raise unless provider_api_error?(e)

        ambiguous_result(field: field, reason: "#{e.class.name}: #{e.message.to_s.first(200)}")
      end

      def run_async
        Thread.new do
          Rails.application.executor.wrap do
            yield
          end
        end
      end

      def result_from_payload(field:, payload:)
        status = payload["status"].to_s
        return ambiguous_result(field: field, reason: "Unsupported VLM status #{status.inspect}") unless STATUSES.include?(status)

        Result.new(
          field: field.name,
          status: status,
          page: Integer(payload["page"], exception: false),
          reason: payload["reason"].to_s.first(300),
          model_id: @model
        )
      end

      def ambiguous_result(field:, reason:)
        Result.new(
          field: field.name,
          status: "ambiguous",
          page: field.page,
          reason: reason,
          model_id: @model
        )
      end

      def system_prompt
        "You inspect COLA label artwork for one unresolved field. " \
          "Return only whether the expected value is present, absent, or ambiguous. " \
          "Do not transcribe or invent label text."
      end

      def anthropic_system_prompt
        "#{system_prompt} Return JSON only matching this schema: #{JSON.generate(response_schema)}"
      end

      def user_content(field:, image:, content_type:)
        [
          {
            type: :text,
            text: JSON.generate({
              field: field.name,
              expected_value: field.expected_text,
              page: field.page,
              instruction: field_instruction(field)
            })
          },
          image_block(image: image, content_type: content_type)
        ]
      end

      def anthropic_user_content(field:, image:, content_type:)
        [
          {
            type: "text",
            text: JSON.generate({
              field: field.name,
              expected_value: field.expected_text,
              page: field.page,
              instruction: field_instruction(field)
            })
          },
          anthropic_image_block(image: image, content_type: content_type)
        ]
      end

      def field_instruction(field)
        case field.name
        when "brand_name", "fanciful_name"
          "Return presence only. Product identity text may be stylized, line-broken, or split across nearby label regions. " \
            "Return present when all meaningful expected words are visible somewhere on the label, even if not contiguous. " \
            "Return absent when a distinctive expected word or phrase is not visible. Do not return bounding boxes or coordinates."
        else
          "Return presence only. Do not return bounding boxes or coordinates."
        end
      end

      def image_block(image:, content_type:)
        {
          type: :image_url,
          image_url: {
            url: "data:#{content_type};base64,#{Base64.strict_encode64(image)}",
            detail: "low"
          }
        }
      end

      def anthropic_image_block(image:, content_type:)
        {
          type: "image",
          source: {
            type: "base64",
            media_type: content_type,
            data: Base64.strict_encode64(image)
          }
        }
      end

      def provider_api_error?(error)
        error.class.name.start_with?("OpenAI::Errors::", "Anthropic::Errors::")
      end

      def response_schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "properties" => {
            "status" => { "type" => "string", "enum" => STATUSES },
            "page" => { "type" => "integer" },
            "reason" => { "type" => "string" }
          },
          "required" => %w[status page reason]
        }
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      end
    end
  end
end
