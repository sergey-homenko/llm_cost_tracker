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
          cached_input_tokens: cached_input_tokens(usage)
        )
      end

      def cached_input_tokens(usage)
        details = usage["prompt_tokens_details"] || usage["input_tokens_details"] || {}
        details["cached_tokens"]
      end
    end
  end
end
