# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

require_relative "response_parser"
require_relative "service_charges"

module LlmCostTracker
  module Providers
    module Openai
      module StreamParser
        RETAINED_RESPONSE_FIELDS = %w[id model service_tier background usage].freeze

        def parse_stream(response_status:, request_url: nil, request_body: nil, events: [], **)
          return nil unless response_status == 200

          request = safe_json_parse(request_body)
          usage = stream_usage(events)
          attributes = stream_attributes(events, request: request, request_url: request_url, usage: usage)
          background = find_event_value(events) { |data| data.dig("response", "background") }
          if usage
            event = ResponseParser.usage_event(
              usage, stream: true, usage_source: Usage::Source::STREAM_FINAL, **attributes
            )
            return background ? event.keyed_by_response_id : event
          end

          warn_missing_stream_usage(request_url: request_url, request: request)
          attributes[:service_line_items] = [] if background
          build_unknown_stream_usage(**attributes)
        end

        def streaming_request?(request_url, request_parsed)
          super || request_parsed["stream_format"] == "sse"
        end

        def auto_enable_stream_usage?(request_url, _request_parsed)
          openai_chat_completions_url?(request_url)
        end

        def retain_stream_event?(data)
          data.is_a?(Hash) && (data["item"].is_a?(Hash) || data["response"].is_a?(Hash))
        end

        def trim_stream_event(data)
          return data unless data.is_a?(Hash)

          item, response = data.values_at("item", "response")
          data = data.merge("item" => ServiceCharges.billing_fields(item)) if item
          return data unless response.is_a?(Hash)

          output = Array(response["output"]).filter_map { |output_item| ServiceCharges.billing_fields(output_item) }
          data.merge("response" => response.slice(*RETAINED_RESPONSE_FIELDS).merge("output" => output))
        end

        private

        def stream_attributes(events, request:, request_url:, usage:)
          provider = provider_for(request_url)
          model = stream_value(events, "model", reverse: true) || request["model"]
          service_tier = stream_value(events, "service_tier", reverse: true) || usage&.dig(:service_tier) ||
                         request["service_tier"]
          {
            provider: provider,
            model: model,
            provider_response_id: stream_value(events, "id"),
            pricing_mode: ResponseParser.combined_pricing_mode(
              provider: provider, host: parsed_uri(request_url)&.host, model: model, service_tier: service_tier
            ),
            service_line_items: ServiceCharges.service_line_items_for(streamed_response(events), request:, model:) +
              ServiceCharges.speech_line_items(request)
          }
        end

        def stream_value(events, key, reverse: false)
          find_event_value(events, reverse: reverse) { |data| envelope_value(data, key) }
        end

        def envelope_value(data, key)
          data[key] || data.dig("response", key) || data.dig("chunk", key)
        end

        def stream_usage(events)
          usage = find_event_value(events, reverse: true) do |data|
            found = envelope_value(data, "usage") || data.dig("x_groq", "usage") || data.dig("chunk", "x_groq", "usage")
            next unless found.is_a?(Hash)

            audio = { "output_tokens_details" => { "audio_tokens" => found["output_tokens"] } }
            data["type"] == "speech.audio.done" ? found.merge(audio) : found
          end
          usage&.deep_symbolize_keys
        end

        def streamed_response(events)
          response = { "output" => [] }
          each_event_data(events) do |data|
            response["output"].concat(Array(data.dig("response", "output")))
            response["output"] << data["item"] if data["item"]
            chunk = data["chunk"] || data
            next unless chunk["choices"].is_a?(Array)

            response["id"] ||= chunk["id"]
            response["choices"] ||= chunk["choices"]
          end
          response
        end

        def warn_missing_stream_usage(request_url:, request:)
          return unless request_url.nil? || request["stream"]
          return unless request_url ? openai_chat_completions_url?(request_url) : request["messages"]
          return if request.dig("stream_options", "include_usage")

          Logging.warn(
            "OpenAI-compatible chat-completions stream finished without a final usage chunk. " \
            "Set `stream_options: { include_usage: true }` in your request body so the gem can " \
            "record token counts. This call was stored with usage_source=#{Usage::Source::UNKNOWN}."
          )
        end

        def openai_chat_completions_url?(request_url)
          uri = parsed_uri(request_url)
          uri && uri.path.to_s.end_with?("/chat/completions")
        end
      end
    end
  end
end
