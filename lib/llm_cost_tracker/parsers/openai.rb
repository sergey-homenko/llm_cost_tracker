# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"

module LlmCostTracker
  module Parsers
    class Openai < Base
      include OpenaiUsage

      HOSTS = %w[
        api.openai.com
        us.api.openai.com
        eu.api.openai.com
        au.api.openai.com
        ca.api.openai.com
        jp.api.openai.com
        in.api.openai.com
        sg.api.openai.com
        kr.api.openai.com
        gb.api.openai.com
        ae.api.openai.com
      ].freeze
      TRACKED_PATHS = %w[/v1/chat/completions /v1/completions /v1/embeddings /v1/responses].freeze

      def match?(url)
        match_uri?(url, hosts: HOSTS, exact_paths: TRACKED_PATHS)
      end

      def provider_names
        %w[openai]
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
        openai_chat_completions_url?(request_url)
      end

      private

      def provider_for(_request_url)
        "openai"
      end
    end
  end
end
