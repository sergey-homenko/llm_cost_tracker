# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class Openai < Base
      include OpenaiUsage

      HOSTS = %w[api.openai.com].freeze
      TRACKED_PATHS = %w[/v1/chat/completions /v1/completions /v1/embeddings /v1/responses].freeze

      def match?(url)
        uri_matches?(url) { |uri| host_matches?(uri, HOSTS) && TRACKED_PATHS.include?(uri.path) }
      end

      def provider_names
        %w[openai]
      end

      def parse(request_url, request_body, response_status, response_body)
        parse_openai_usage(request_url, request_body, response_status, response_body)
      end

      def parse_stream(request_url, request_body, response_status, events)
        parse_openai_stream_usage(request_url, request_body, response_status, events)
      end

      private

      def provider_for(_request_url)
        "openai"
      end
    end
  end
end
