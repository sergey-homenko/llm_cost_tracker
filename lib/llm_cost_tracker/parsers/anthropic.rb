# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Parsers
    class Anthropic < Base
      HOSTS = %w[api.anthropic.com].freeze

      def match?(url)
        match_uri?(url, hosts: HOSTS, path_includes: "/v1/messages")
      end

      def provider_names
        %w[anthropic]
      end

      def parse(_request_url, request_body, response_status, response_body)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usage"]
        return nil unless usage

        request = safe_json_parse(request_body)
        cache_read = usage["cache_read_input_tokens"].to_i
        cache_write = usage["cache_creation_input_tokens"].to_i

        ParsedUsage.build(
          provider: "anthropic",
          provider_response_id: response["id"],
          model: response["model"] || request["model"],
          input_tokens: usage["input_tokens"].to_i,
          output_tokens: usage["output_tokens"].to_i,
          total_tokens: usage["input_tokens"].to_i + usage["output_tokens"].to_i + cache_read + cache_write,
          cache_read_input_tokens: usage["cache_read_input_tokens"],
          cache_write_input_tokens: usage["cache_creation_input_tokens"],
          usage_source: :response
        )
      end

      def parse_stream(_request_url, request_body, response_status, events)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        model = stream_model(events) || request["model"]
        usage = stream_usage(events)
        response_id = stream_response_id(events)

        if usage
          build_stream_result(model, usage, response_id)
        else
          build_unknown_stream_usage(
            provider: "anthropic",
            model: model,
            provider_response_id: response_id
          )
        end
      end

      private

      def stream_usage(events)
        start_usage = find_event_value(events, reverse: true) do |data|
          data.dig("message", "usage") if data["type"] == "message_start"
        end
        latest_delta = find_event_value(events, reverse: true) do |data|
          data["usage"] if data["type"] == "message_delta" && data["usage"].is_a?(Hash)
        end

        return nil unless start_usage || latest_delta

        (start_usage || {}).merge(latest_delta || {}) do |_key, start_val, delta_val|
          delta_val.nil? ? start_val : delta_val
        end
      end

      def stream_model(events)
        find_event_value(events) { |data| data.dig("message", "model") }
      end

      def stream_response_id(events)
        find_event_value(events) { |data| data.dig("message", "id") || data["id"] }
      end

      def build_stream_result(model, usage, response_id)
        input = usage["input_tokens"].to_i
        output = usage["output_tokens"].to_i
        cache_read = usage["cache_read_input_tokens"].to_i
        cache_write = usage["cache_creation_input_tokens"].to_i

        ParsedUsage.build(
          provider: "anthropic",
          provider_response_id: response_id,
          model: model,
          input_tokens: input,
          output_tokens: output,
          total_tokens: input + output + cache_read + cache_write,
          cache_read_input_tokens: usage["cache_read_input_tokens"],
          cache_write_input_tokens: usage["cache_creation_input_tokens"],
          stream: true,
          usage_source: :stream_final
        )
      end
    end
  end
end
