# frozen_string_literal: true

require "json"
require "uri"

require_relative "base"

module LlmCostTracker
  module Parsers
    class Gemini < Base
      HOSTS = %w[generativelanguage.googleapis.com].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        HOSTS.include?(uri.host.to_s.downcase)
      rescue URI::InvalidURIError
        false
      end

      def parse(request_url, _request_body, response_status, response_body)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usageMetadata"]
        return nil unless usage

        # Extract model from URL: /v1beta/models/gemini-2.5-flash:generateContent
        model = extract_model_from_url(request_url)

        {
          provider: "gemini",
          model: model,
          input_tokens: usage["promptTokenCount"] || 0,
          output_tokens: output_tokens(usage),
          total_tokens: usage["totalTokenCount"] || 0,
          cached_input_tokens: usage["cachedContentTokenCount"]
        }.compact
      end

      private

      def output_tokens(usage)
        (usage["candidatesTokenCount"] || 0) + (usage["thoughtsTokenCount"] || 0)
      end

      def extract_model_from_url(url)
        uri = URI.parse(url.to_s)
        match = uri.path.match(%r{/models/([^/:]+)})
        match ? match[1] : "unknown"
      rescue URI::InvalidURIError
        "unknown"
      end
    end
  end
end
