# frozen_string_literal: true

require "uri"

require_relative "base"

module LlmCostTracker
  module Parsers
    class Anthropic < Base
      HOSTS = %w[api.anthropic.com].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        HOSTS.include?(uri.host.to_s.downcase) && uri.path.include?("/v1/messages")
      rescue URI::InvalidURIError
        false
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

        ParsedUsage.build(
          provider: "anthropic",
          model: response["model"] || request["model"],
          input_tokens: usage["input_tokens"].to_i,
          output_tokens: usage["output_tokens"].to_i,
          total_tokens: usage["input_tokens"].to_i + usage["output_tokens"].to_i +
            usage["cache_read_input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i,
          cache_read_input_tokens: usage["cache_read_input_tokens"],
          cache_creation_input_tokens: usage["cache_creation_input_tokens"],
          usage_source: :response
        )
      end

      def parse_stream(_request_url, request_body, response_status, events)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        model = stream_model(events) || request["model"]
        usage = stream_usage(events)

        if usage
          input = usage["input_tokens"].to_i
          output = usage["output_tokens"].to_i
          cache_read = usage["cache_read_input_tokens"].to_i
          cache_creation = usage["cache_creation_input_tokens"].to_i

          ParsedUsage.build(
            provider: "anthropic",
            model: model,
            input_tokens: input,
            output_tokens: output,
            total_tokens: input + output + cache_read + cache_creation,
            cache_read_input_tokens: usage["cache_read_input_tokens"],
            cache_creation_input_tokens: usage["cache_creation_input_tokens"],
            stream: true,
            usage_source: :stream_final
          )
        else
          ParsedUsage.build(
            provider: "anthropic",
            model: model,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            stream: true,
            usage_source: :unknown
          )
        end
      end

      private

      def stream_usage(events)
        start_usage = nil
        latest_delta = nil

        events.each do |event|
          data = event[:data]
          next unless data.is_a?(Hash)

          case data["type"]
          when "message_start"
            start_usage = data.dig("message", "usage")
          when "message_delta"
            latest_delta = data["usage"] if data["usage"].is_a?(Hash)
          end
        end

        return nil unless start_usage || latest_delta

        (start_usage || {}).merge(latest_delta || {}) do |_key, start_val, delta_val|
          delta_val.nil? ? start_val : delta_val
        end
      end

      def stream_model(events)
        events.each do |event|
          data = event[:data]
          next unless data.is_a?(Hash)

          model = data.dig("message", "model")
          return model if model && !model.empty?
        end
        nil
      end
    end
  end
end
