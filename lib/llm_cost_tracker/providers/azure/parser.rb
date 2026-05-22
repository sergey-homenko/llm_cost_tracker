# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../openai/usage_parser"
require_relative "hosts"

module LlmCostTracker
  module Providers
    module Azure
      class Parser < LlmCostTracker::Parsers::Base
        include Openai::UsageParser

        TRACKED_ENDPOINTS = %w[
          chat/completions completions embeddings moderations responses
          audio/transcriptions audio/translations audio/speech
          images/generations images/edits images/variations
        ].freeze

        PATH_PATTERN = %r{\A/openai/(?:deployments/[^/]+|v1)/(?:#{TRACKED_ENDPOINTS.join('|')})\z}

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
      end
    end
  end
end
