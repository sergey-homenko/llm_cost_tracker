# frozen_string_literal: true

require "json"
require "uri"

require_relative "base"

module LlmCostTracker
  module Parsers
    class Openai < Base
      HOSTS = %w[api.openai.com].freeze
      TRACKED_PATHS = %w[/v1/chat/completions /v1/completions /v1/embeddings /v1/responses].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        HOSTS.include?(uri.host.to_s.downcase) && TRACKED_PATHS.include?(uri.path)
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
          provider: provider_for(request_url),
          model: response["model"] || request["model"],
          input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
          output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
          total_tokens: usage["total_tokens"] || 0,
          cached_input_tokens: cached_input_tokens(usage)
        }.compact
      end

      private

      def provider_for(_request_url)
        "openai"
      end

      def cached_input_tokens(usage)
        details = usage["prompt_tokens_details"] || usage["input_tokens_details"] || {}
        details["cached_tokens"]
      end
    end
  end
end
