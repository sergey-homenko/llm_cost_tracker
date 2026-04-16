# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Parsers
    class Openai < Base
      HOSTS = %w[api.openai.com].freeze
      TRACKED_PATHS = %w[/v1/chat/completions /v1/completions /v1/embeddings].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        HOSTS.include?(uri.host) && TRACKED_PATHS.any? { |p| uri.path.start_with?(p) }
      rescue URI::InvalidURIError
        false
      end

      def parse(request_url, request_body, response_status, response_body)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usage"]
        return nil unless usage

        request = safe_json_parse(request_body)

        {
          provider: "openai",
          model: response["model"] || request["model"],
          input_tokens: usage["prompt_tokens"] || 0,
          output_tokens: usage["completion_tokens"] || 0,
          total_tokens: usage["total_tokens"] || 0
        }
      end
    end
  end
end
