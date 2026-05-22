# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Openai
      class Parser < LlmCostTracker::Parsers::Base
        include UsageParser

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
            match_uri?(url, hosts: Hosts::API_HOSTS, exact_paths: TRACKED_PATHS)
          end

          def provider_names
            %w[openai]
          end
        end

        def provider_for(_request_url)
          "openai"
        end
      end
    end
  end
end
