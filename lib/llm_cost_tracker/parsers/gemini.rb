# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Parsers
    class Gemini < Base
      HOSTS = %w[generativelanguage.googleapis.com].freeze

      def match?(url)
        uri = URI.parse(url.to_s)
        HOSTS.include?(uri.host)
      rescue URI::InvalidURIError
        false
      end

      def parse(request_url, request_body, response_status, response_body)
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
          output_tokens: usage["candidatesTokenCount"] || 0,
          total_tokens: usage["totalTokenCount"] || 0
        }
      end

      private

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
