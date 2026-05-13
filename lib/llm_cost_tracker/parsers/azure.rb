# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"
require_relative "../providers/azure/hosts"

module LlmCostTracker
  module Parsers
    class Azure < Base
      include OpenaiUsage

      PATH_PATTERN = %r{
        \A/openai/deployments/[^/]+/
        (chat/completions|completions|embeddings|audio/transcriptions|audio/translations|images/generations)\z
      }x

      class << self
        def match?(url)
          uri_matches?(url) do |uri|
            LlmCostTracker::Providers::Azure::Hosts.openai?(uri.host) && uri.path.to_s.match?(PATH_PATTERN)
          end
        end

        def provider_names
          %w[azure_openai]
        end
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
