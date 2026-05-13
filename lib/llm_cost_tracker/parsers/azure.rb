# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class Azure < Base
      include OpenaiUsage

      HOST_PATTERN = /\A[a-z0-9][a-z0-9-]*\.openai\.azure\.com\z/i
      PATH_PATTERN = %r{
        \A/openai/deployments/[^/]+/
        (chat/completions|completions|embeddings|audio/transcriptions|audio/translations|images/generations)\z
      }x

      def match?(url)
        uri_matches?(url) do |uri|
          uri.host.to_s.downcase.match?(HOST_PATTERN) && uri.path.to_s.match?(PATH_PATTERN)
        end
      end

      def provider_names
        %w[azure_openai]
      end

      def parse(request_url:, request_body:, response_status:, response_body:, **)
        parse_openai_usage(
          request_url: request_url,
          request_body: request_body,
          response_status: response_status,
          response_body: response_body
        )
      end

      def parse_stream(response_status:, request_url: nil, request_body: nil, events: [], **)
        parse_openai_stream_usage(
          request_url: request_url,
          request_body: request_body,
          response_status: response_status,
          events: events
        )
      end

      def auto_enable_stream_usage?(request_url)
        uri = parsed_uri(request_url)
        uri && uri.path.to_s.end_with?("/chat/completions")
      end

      def provider_for(_request_url)
        "azure_openai"
      end
    end
  end
end
