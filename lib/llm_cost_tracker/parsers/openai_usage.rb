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

        ParsedUsage.build(
          provider: provider_for(request_url),
          model: response["model"] || request["model"],
          input_tokens: (usage["prompt_tokens"] || usage["input_tokens"]).to_i,
          output_tokens: (usage["completion_tokens"] || usage["output_tokens"]).to_i,
          total_tokens: usage["total_tokens"].to_i,
          cached_input_tokens: cached_input_tokens(usage),
          usage_source: :response
        )
      end

      def parse_openai_stream_usage(request_url, request_body, response_status, events)
        return nil unless response_status == 200

        request = safe_json_parse(request_body)
        model = detect_stream_model(events) || request["model"]
        usage = detect_stream_usage(events)

        if usage
          ParsedUsage.build(
            provider: provider_for(request_url),
            model: model,
            input_tokens: (usage["prompt_tokens"] || usage["input_tokens"]).to_i,
            output_tokens: (usage["completion_tokens"] || usage["output_tokens"]).to_i,
            total_tokens: usage["total_tokens"].to_i,
            cached_input_tokens: cached_input_tokens(usage),
            stream: true,
            usage_source: :stream_final
          )
        else
          ParsedUsage.build(
            provider: provider_for(request_url),
            model: model,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            stream: true,
            usage_source: :unknown
          )
        end
      end

      def detect_stream_usage(events)
        events.reverse_each do |event|
          data = event[:data]
          next unless data.is_a?(Hash)

          usage = data["usage"]
          return usage if usage.is_a?(Hash) && !usage.empty?
        end
        nil
      end

      def detect_stream_model(events)
        events.each do |event|
          data = event[:data]
          next unless data.is_a?(Hash)

          model = data["model"]
          return model if model && !model.to_s.empty?
        end
        nil
      end

      def cached_input_tokens(usage)
        details = usage["prompt_tokens_details"] || usage["input_tokens_details"] || {}
        details["cached_tokens"]
      end
    end
  end
end
