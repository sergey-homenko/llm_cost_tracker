# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Azure
      class Parser < LlmCostTracker::Parsers::Base
        include Openai::ResponseParser

        PATH_PATTERN = %r{\A/openai/(?:deployments/[^/]+|v1)/(?:#{Openai::Parser::TRACKED_ENDPOINTS.join('|')})\z}

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
          super && stream_options_api?(parsed_uri(request_url)) &&
            !request_parsed.key?("data_sources") && !image_input?(request_parsed)
        end

        private

        def stream_options_api?(uri)
          uri.path.start_with?("/openai/v1/") ||
            uri.query.to_s[/api-version=(\d{4}-\d{2}-\d{2})/, 1].to_s >= "2024-06-01"
        end

        def image_input?(request)
          Array(request["messages"]).any? do |message|
            message.is_a?(Hash) &&
              Array(message["content"]).any? { |part| part.is_a?(Hash) && part["type"] == "image_url" }
          end
        end
      end
    end
  end
end
