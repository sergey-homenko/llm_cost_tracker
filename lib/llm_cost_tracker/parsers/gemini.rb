# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Parsers
    class Gemini < Base
      HOSTS = %w[generativelanguage.googleapis.com].freeze
      TRACKED_PATH_PATTERN = %r{/models/[^/:]+:(?:generateContent|streamGenerateContent)\z}
      STREAM_PATH_PATTERN  = /:streamGenerateContent\z/

      def match?(url)
        match_uri?(url, hosts: HOSTS, path_pattern: TRACKED_PATH_PATTERN)
      end

      def provider_names
        %w[gemini]
      end

      def streaming_request?(request_url, request_body)
        return true if match_uri?(request_url, path_pattern: STREAM_PATH_PATTERN)

        super
      end

      def parse(request_url:, request_body:, response_status:, response_body:, response_headers: nil)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usageMetadata"]
        return nil unless usage

        request = safe_json_parse(request_body)
        build_usage_capture(
          request_url: request_url,
          usage: usage,
          usage_source: :response,
          provider_response_id: response["responseId"],
          pricing_mode: pricing_mode(request: request, response_headers: response_headers)
        )
      end

      def parse_stream(response_status:, request_url: nil, request_body: nil, events: [], response_headers: nil)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        usage = merged_stream_usage(events)
        model = extract_model_from_url(request_url)
        response_id = stream_response_id(events)
        mode = pricing_mode(request: request, response_headers: response_headers)

        if usage
          build_usage_capture(
            request_url: request_url,
            usage: usage,
            stream: true,
            usage_source: :stream_final,
            provider_response_id: response_id,
            pricing_mode: mode
          )
        else
          build_unknown_stream_usage(
            provider: "gemini",
            model: model,
            provider_response_id: response_id,
            pricing_mode: mode
          )
        end
      end

      private

      def build_usage_capture(request_url:, usage:, usage_source:, stream: false, provider_response_id: nil,
                              pricing_mode: nil)
        cache_read = usage["cachedContentTokenCount"].to_i
        tool_use_prompt = usage["toolUsePromptTokenCount"].to_i

        UsageCapture.build(
          provider: "gemini",
          model: extract_model_from_url(request_url),
          pricing_mode: pricing_mode,
          token_usage: TokenUsage.build(
            input_tokens: [usage["promptTokenCount"].to_i - cache_read, 0].max + tool_use_prompt,
            output_tokens: output_tokens(usage),
            total_tokens: total_tokens(usage: usage, cache_read: cache_read, tool_use_prompt: tool_use_prompt),
            cache_read_input_tokens: usage["cachedContentTokenCount"],
            hidden_output_tokens: usage["thoughtsTokenCount"]
          ),
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id
        )
      end

      def merged_stream_usage(events)
        find_event_value(events, reverse: true) do |data|
          meta = data["usageMetadata"]
          meta if meta.is_a?(Hash)
        end
      end

      def output_tokens(usage)
        usage["candidatesTokenCount"].to_i + usage["thoughtsTokenCount"].to_i
      end

      def total_tokens(usage:, cache_read:, tool_use_prompt:)
        total = usage["totalTokenCount"]
        return total.to_i unless total.nil?

        [usage["promptTokenCount"].to_i - cache_read, 0].max + cache_read + tool_use_prompt + output_tokens(usage)
      end

      def stream_response_id(events)
        find_event_value(events) { |data| data["responseId"] }
      end

      def extract_model_from_url(url)
        uri = parsed_uri(url)
        return nil unless uri

        match = uri.path.match(%r{/models/([^/:]+)})
        match && match[1]
      end

      def pricing_mode(request:, response_headers:)
        response_tier = response_header(response_headers, "x-gemini-service-tier")
        response_mode = Pricing.normalize_mode(response_tier)
        return response_mode if response_mode

        request_mode = Pricing.normalize_mode(
          request["service_tier"] ||
          request["serviceTier"] ||
          request.dig("config", "service_tier") ||
          request.dig("config", "serviceTier")
        )
        request_mode == "flex" ? request_mode : nil
      end

      def response_header(headers, name)
        headers.to_h.find { |key, _value| key.to_s.downcase == name }&.last
      end
    end
  end
end
