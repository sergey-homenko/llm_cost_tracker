# frozen_string_literal: true

require_relative "base"
require_relative "openai_usage"
require_relative "../providers/openai/hosts"

module LlmCostTracker
  module Parsers
    class Openai < Base
      include OpenaiUsage

      TRACKED_PATHS = %w[
        /v1/chat/completions
        /v1/completions
        /v1/embeddings
        /v1/responses
        /v1/images/generations
        /v1/images/edits
        /v1/images/variations
        /v1/audio/transcriptions
        /v1/audio/translations
        /v1/audio/speech
        /v1/moderations
      ].freeze

      class << self
        def match?(url)
          match_uri?(url, hosts: Providers::Openai::Hosts::API_HOSTS, exact_paths: TRACKED_PATHS)
        end

        def provider_names
          %w[openai]
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
        openai_chat_completions_url?(request_url)
      end

      def provider_for(_request_url)
        "openai"
      end
    end
  end
end
