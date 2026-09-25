# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Azure
      class Parser < LlmCostTracker::Parsers::Base
        include Openai::ResponseParser

        TRACKED_ENDPOINTS = %w[
          chat/completions completions embeddings moderations responses
          audio/transcriptions audio/translations audio/speech
          images/generations images/edits images/variations
        ].freeze

        PATH_PATTERN = %r{\A/openai/(?:deployments/[^/]+|v1)/(?:#{TRACKED_ENDPOINTS.join('|')})\z}

        API_VERSION_PATTERN = /(?:\A|&)api-version=(\d{4}-\d{2}-\d{2})(?:-preview)?(?:&|\z)/
        FIRST_STREAM_OPTIONS_API_VERSION = "2024-06-01"

        class << self
          def match?(url)
            uri_matches?(url) do |uri|
              Hosts.openai?(uri.host) && uri.path.to_s.match?(PATH_PATTERN)
            end
          end

          def provider_names
            %w[azure_openai]
          end
        end

        def provider_for(_request_url)
          "azure_openai"
        end

        def model_for(request_url, request_parsed)
          body_model = super
          return body_model if body_model

          uri = parsed_uri(request_url)
          match = uri&.path&.match(%r{/openai/deployments/([^/]+)/})
          match && match[1]
        end

        def auto_enable_stream_usage?(request_url, request_parsed)
          super && stream_options_api?(parsed_uri(request_url)) && !stream_options_rejected?(request_parsed)
        end

        private

        def stream_options_api?(uri)
          return true if uri.path.to_s.start_with?("/openai/v1/")

          version_date = uri.query.to_s[API_VERSION_PATTERN, 1]
          !version_date.nil? && version_date >= FIRST_STREAM_OPTIONS_API_VERSION
        end

        def stream_options_rejected?(request)
          return true unless request["data_sources"].nil?

          Array(request["messages"]).any? do |message|
            message.is_a?(Hash) &&
              Array(message["content"]).any? { |part| part.is_a?(Hash) && part["type"] == "image_url" }
          end
        end

        def missing_stream_usage_advice
          "Azure OpenAI accepts `stream_options: { include_usage: true }` on the v1 API and on " \
            "api-version 2024-06-01 or later, except with On Your Data or image input; " \
            "set it in your request body there so the gem can record token counts."
        end
      end
    end
  end
end
