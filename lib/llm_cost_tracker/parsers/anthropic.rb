# frozen_string_literal: true

require "json"
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

      def parse(_request_url, request_body, response_status, response_body)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usage"]
        return nil unless usage

        request = safe_json_parse(request_body)

        {
          provider: "anthropic",
          model: response["model"] || request["model"],
          input_tokens: usage["input_tokens"] || 0,
          output_tokens: usage["output_tokens"] || 0,
          total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0) +
            (usage["cache_read_input_tokens"] || 0) +
            (usage["cache_creation_input_tokens"] || 0),
          cache_read_input_tokens: usage["cache_read_input_tokens"],
          cache_creation_input_tokens: usage["cache_creation_input_tokens"]
        }.compact
      end
    end
  end
end
