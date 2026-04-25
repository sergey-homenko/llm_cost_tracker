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

      def match_uri?(url, hosts: nil, exact_paths: nil, path_includes: nil, path_suffixes: nil, path_pattern: nil)
        uri_matches?(url) do |uri|
          host_match = hosts.nil? || host_matches?(uri, hosts)
          path_match = path_matches?(
            uri,
            exact_paths: exact_paths,
            path_includes: path_includes,
            path_suffixes: path_suffixes,
            path_pattern: path_pattern
          )
          extra_match = block_given? ? yield(uri) : true

          host_match && path_match && extra_match ? true : false
        end
      end

      def parsed_uri(url)
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        nil
      end

      def host_matches?(uri, hosts)
        hosts.include?(uri.host.to_s.downcase)
      end

      def path_matches?(uri, exact_paths: nil, path_includes: nil, path_suffixes: nil, path_pattern: nil)
        path = uri.path.to_s
        matches = true

        matches &&= exact_paths.include?(path) if exact_paths
        matches &&= Array(path_includes).all? { |fragment| path.include?(fragment) } if path_includes
        matches &&= path.match?(path_pattern) if path_pattern

        matches &&= path_suffixes.any? { |suffix| path == suffix || path.end_with?(suffix) } if path_suffixes

        matches
      end

      def each_event_data(events, reverse: false)
        enumerator = reverse ? events.reverse_each : events.each

        enumerator.each do |event|
          data = event[:data]
          yield data if data.is_a?(Hash)
        end
      end

      def find_event_value(events, reverse: false)
        each_event_data(events, reverse:) do |data|
          value = yield(data)
          return value if event_value_present?(value)
        end

        nil
      end

      def build_unknown_stream_usage(provider:, model:, provider_response_id:)
        ParsedUsage.build(
          provider: provider,
          provider_response_id: provider_response_id,
          model: model || ParsedUsage::UNKNOWN_MODEL,
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          stream: true,
          usage_source: :unknown
        )
      end

      def event_value_present?(value)
        !value.nil? && (!value.respond_to?(:empty?) || !value.empty?)
      end
    end
  end
end
