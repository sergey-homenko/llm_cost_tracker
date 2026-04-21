# frozen_string_literal: true

require "uri"

require_relative "base"

module LlmCostTracker
  module Parsers
    class Gemini < Base
      HOSTS = %w[generativelanguage.googleapis.com].freeze
      TRACKED_PATH_PATTERN = %r{/models/[^/:]+:(?:generateContent|streamGenerateContent)\z}
      STREAM_PATH_PATTERN  = /:streamGenerateContent\z/

      def match?(url)
        uri = URI.parse(url.to_s)
        HOSTS.include?(uri.host.to_s.downcase) && uri.path.match?(TRACKED_PATH_PATTERN)
      rescue URI::InvalidURIError
        false
      end

      def provider_names
        %w[gemini]
      end

      def streaming_request?(request_url, request_body)
        return true if streaming_url?(request_url)

        super
      end

      def parse(request_url, _request_body, response_status, response_body)
        return nil unless response_status == 200

        response = safe_json_parse(response_body)
        usage    = response["usageMetadata"]
        return nil unless usage

        build_parsed_usage(request_url, usage, usage_source: :response)
      end

      def parse_stream(request_url, _request_body, response_status, events)
        return nil unless response_status == 200

        usage = merged_stream_usage(events)
        model = extract_model_from_url(request_url)

        if usage
          build_parsed_usage(request_url, usage, stream: true, usage_source: :stream_final)
        else
          ParsedUsage.build(
            provider: "gemini",
            model: model,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            stream: true,
            usage_source: :unknown
          )
        end
      end

      private

      def build_parsed_usage(request_url, usage, usage_source:, stream: false)
        ParsedUsage.build(
          provider: "gemini",
          model: extract_model_from_url(request_url),
          input_tokens: usage["promptTokenCount"].to_i,
          output_tokens: output_tokens(usage),
          total_tokens: usage["totalTokenCount"].to_i,
          cached_input_tokens: usage["cachedContentTokenCount"],
          stream: stream,
          usage_source: usage_source
        )
      end

      def merged_stream_usage(events)
        latest = nil
        events.each do |event|
          data = event[:data]
          next unless data.is_a?(Hash)

          meta = data["usageMetadata"]
          latest = meta if meta.is_a?(Hash)
        end
        latest
      end

      def output_tokens(usage)
        usage["candidatesTokenCount"].to_i + usage["thoughtsTokenCount"].to_i
      end

      def streaming_url?(request_url)
        URI.parse(request_url.to_s).path.match?(STREAM_PATH_PATTERN)
      rescue URI::InvalidURIError
        false
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
