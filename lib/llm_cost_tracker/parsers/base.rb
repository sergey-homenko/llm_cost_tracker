# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Parsers
    class Base
      # Parse a provider response into a {LlmCostTracker::ParsedUsage}, or return
      # nil when the response is not trackable (non-200, missing usage, etc).
      #
      # @return [LlmCostTracker::ParsedUsage, nil]
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
