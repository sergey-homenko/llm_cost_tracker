# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Parsers
    class Base
      # Returns a hash with parsed usage data, or nil if not applicable.
      #
      # Expected return format:
      # {
      #   provider: "openai",
      #   model: "gpt-4o",
      #   input_tokens: 150,
      #   output_tokens: 42
      # }
      def parse(request_url, request_body, response_status, response_body)
        raise NotImplementedError
      end

      # Returns true if this parser can handle the given URL.
      def match?(url)
        raise NotImplementedError
      end

      private

      def safe_json_parse(body)
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
