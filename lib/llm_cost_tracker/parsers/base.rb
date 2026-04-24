# frozen_string_literal: true

require "json"
require "uri"

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

        request = safe_json_parse(body)
        request.is_a?(Hash) && request["stream"] == true
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

      def uri_matches?(url)
        uri = parsed_uri(url)
        uri ? yield(uri) : false
      end

      def parsed_uri(url)
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        nil
      end

      def host_matches?(uri, hosts)
        hosts.include?(uri.host.to_s.downcase)
      end
    end
  end
end
