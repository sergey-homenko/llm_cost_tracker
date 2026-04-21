# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Parsers
    class Base
      def parse(request_url, request_body, response_status, response_body)
        raise NotImplementedError
      end

      def provider_names
        []
      end

      def match?(url)
        raise NotImplementedError
      end

      def streaming_request?(_request_url, request_body)
        return false if request_body.nil?

        body = request_body.to_s
        return false if body.empty?

        body.include?('"stream":true') || body.include?('"stream": true') || body.include?("stream: true")
      end

      def parse_stream(_request_url, _request_body, _response_status, _events)
        nil
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
