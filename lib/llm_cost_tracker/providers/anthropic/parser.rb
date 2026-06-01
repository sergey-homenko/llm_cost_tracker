# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module LlmCostTracker
  module Providers
    module Anthropic
      class Parser < LlmCostTracker::Parsers::Base
        HOSTS = %w[api.anthropic.com].freeze

        class << self
          def match?(url)
            match_uri?(url, hosts: HOSTS, path_includes: "/v1/messages")
          end

          def provider_names
            %w[anthropic]
          end
        end

        def parse(request_body:, response_status:, response_body:, **)
          return nil unless response_status == 200

          response = safe_json_parse(response_body)
          usage = response["usage"]&.deep_symbolize_keys
          return nil unless usage

          request = symbolize_request(request_body)

          Event.build(
            provider: "anthropic",
            provider_response_id: response["id"],
            pricing_mode: UsageExtractor.pricing_mode(request: request, usage: usage),
            model: response["model"] || request[:model],
            token_usage: UsageExtractor.token_usage(usage),
            usage_source: Capture::UsageSource::RESPONSE,
            service_line_items: UsageExtractor.service_line_items(usage)
          )
        end

        def parse_stream(response_status:, request_body: nil, events: [], **)
          return nil unless response_status == 200

          request = symbolize_request(request_body)
          model = find_event_value(events) { |data| data.dig("message", "model") } || request[:model]
          usage = stream_usage(events)&.deep_symbolize_keys
          response_id = find_event_value(events) { |data| data.dig("message", "id") || data["id"] }

          if usage
            build_stream_result(model: model, usage: usage, response_id: response_id, request: request)
          else
            build_unknown_stream_usage(
              provider: "anthropic",
              model: model,
              provider_response_id: response_id,
              pricing_mode: UsageExtractor.pricing_mode(request: request, usage: usage)
            )
          end
        end

        def provider_for(_request_url)
          "anthropic"
        end

        private

        def symbolize_request(request_body)
          parsed = safe_json_parse(request_body)
          parsed.is_a?(Hash) ? parsed.deep_symbolize_keys : {}
        end

        def stream_usage(events)
          latest_delta = find_event_value(events, reverse: true) do |data|
            data["usage"] if data["type"] == "message_delta" && data["usage"].is_a?(Hash)
          end
          return nil unless latest_delta

          start_usage = find_event_value(events, reverse: true) do |data|
            data.dig("message", "usage") if data["type"] == "message_start"
          end

          (start_usage || {}).merge(latest_delta) do |_key, start_val, delta_val|
            delta_val || start_val
          end
        end

        def build_stream_result(model:, usage:, response_id:, request:)
          Event.build(
            provider: "anthropic",
            provider_response_id: response_id,
            pricing_mode: UsageExtractor.pricing_mode(request: request, usage: usage),
            model: model,
            token_usage: UsageExtractor.token_usage(usage),
            stream: true,
            usage_source: Capture::UsageSource::STREAM_FINAL,
            service_line_items: UsageExtractor.service_line_items(usage)
          )
        end
      end
    end
  end
end
