# frozen_string_literal: true

module LlmCostTracker
  module Parsers
    module OpenaiUsage
      private

      def parse_openai_usage(request_url, request_body, response_status, response_body)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage = response["usage"]
        return nil unless usage

        request = safe_json_parse(request_body)
        cache_read = cache_read_input_tokens(usage)

        ParsedUsage.build(
          provider: provider_for(request_url),
          provider_response_id: response["id"],
          model: response["model"] || request["model"],
          input_tokens: regular_input_tokens(usage, cache_read),
          output_tokens: (usage["completion_tokens"] || usage["output_tokens"]).to_i,
          total_tokens: usage["total_tokens"].to_i,
          cache_read_input_tokens: cache_read,
          hidden_output_tokens: hidden_output_tokens(usage),
          usage_source: :response
        )
      end

      def parse_openai_stream_usage(request_url, request_body, response_status, events)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        model = detect_stream_model(events) || request["model"]
        usage = detect_stream_usage(events)
        response_id = detect_stream_response_id(events)

        if usage
          cache_read = cache_read_input_tokens(usage)
          ParsedUsage.build(
            provider: provider_for(request_url),
            provider_response_id: response_id,
            model: model,
            input_tokens: regular_input_tokens(usage, cache_read),
            output_tokens: (usage["completion_tokens"] || usage["output_tokens"]).to_i,
            total_tokens: usage["total_tokens"].to_i,
            cache_read_input_tokens: cache_read,
            hidden_output_tokens: hidden_output_tokens(usage),
            stream: true,
            usage_source: :stream_final
          )
        else
          build_unknown_stream_usage(
            provider: provider_for(request_url),
            model: model,
            provider_response_id: response_id
          )
        end
      end

      def detect_stream_usage(events)
        find_event_value(events, reverse: true) do |data|
          usage = data["usage"]
          usage if usage.is_a?(Hash)
        end
      end

      def detect_stream_model(events)
        find_event_value(events) { |data| data["model"] || data.dig("response", "model") }
      end

      def detect_stream_response_id(events)
        find_event_value(events) { |data| data["id"] || data.dig("response", "id") }
      end

      def regular_input_tokens(usage, cache_read)
        [(usage["prompt_tokens"] || usage["input_tokens"]).to_i - cache_read.to_i, 0].max
      end

      def cache_read_input_tokens(usage)
        details = usage["prompt_tokens_details"] || usage["input_tokens_details"] || {}
        details["cached_tokens"]
      end

      def hidden_output_tokens(usage)
        details = usage["completion_tokens_details"] || usage["output_tokens_details"] || {}
        details["reasoning_tokens"]
      end
    end
  end
end
