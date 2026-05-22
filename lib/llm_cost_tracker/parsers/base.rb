# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"
require "uri"

module LlmCostTracker
  module Parsers
    module UrlMatchers
      def match_uri?(url, hosts: nil, exact_paths: nil, path_includes: nil, path_suffixes: nil, path_pattern: nil)
        uri_matches?(url) do |uri|
          host_match = hosts.nil? || hosts.include?(uri.host.to_s.downcase)
          path_match = path_matches?(
            uri,
            exact_paths: exact_paths,
            path_includes: path_includes,
            path_suffixes: path_suffixes,
            path_pattern: path_pattern
          )
          extra_match = block_given? ? yield(uri) : true

          !!(host_match && path_match && extra_match)
        end
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

      def path_matches?(uri, exact_paths: nil, path_includes: nil, path_suffixes: nil, path_pattern: nil)
        path = uri.path.to_s
        matches = true
        matches &&= exact_paths.include?(path) if exact_paths
        matches &&= Array(path_includes).all? { |fragment| path.include?(fragment) } if path_includes
        matches &&= path.match?(path_pattern) if path_pattern
        matches &&= path_suffixes.any? { |suffix| path == suffix || path.end_with?(suffix) } if path_suffixes
        matches
      end
    end

    class Base
      extend UrlMatchers
      include UrlMatchers

      class << self
        def match?(_url)
          raise NotImplementedError
        end

        def provider_names
          []
        end
      end

      def parse(**)
        raise NotImplementedError
      end

      def streaming_request?(_request_url, request_parsed)
        request_parsed.is_a?(Hash) && request_parsed["stream"] == true
      end

      def model_for(_request_url, request_parsed)
        request_parsed["model"] if request_parsed.is_a?(Hash)
      end

      def parse_stream(**)
        nil
      end

      def auto_enable_stream_usage?(_request_url)
        false
      end

      def safe_json_parse(body)
        return {} if body.blank?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      private

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
          return value if value.present?
        end

        nil
      end

      def build_unknown_stream_usage(provider:, model:, provider_response_id:, pricing_mode: nil,
                                     service_line_items: nil)
        Event.build(
          provider: provider,
          provider_response_id: provider_response_id,
          pricing_mode: pricing_mode,
          model: model || Event::UNKNOWN_MODEL,
          token_usage: TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: :unknown,
          service_line_items: service_line_items
        )
      end
    end
  end
end
