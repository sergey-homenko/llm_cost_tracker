# frozen_string_literal: true

require_relative "../../parsers"
require_relative "../openai/usage_parser"

module LlmCostTracker
  module Providers
    module OpenaiCompatible
      class Parser < LlmCostTracker::Parsers::Base
        include Openai::UsageParser

        TRACKED_PATH_SUFFIXES = %w[/chat/completions /completions /embeddings /responses].freeze

        class << self
          def match?(url)
            match_uri?(url, path_suffixes: TRACKED_PATH_SUFFIXES) { |uri| provider_for_uri(uri) }
          end

          def provider_names
            custom = LlmCostTracker.configuration.openai_compatible_providers.each_value.map do |provider|
              provider.to_s.downcase
            end
            ["openai_compatible", *custom].uniq
          end

          def provider_for_uri(uri)
            return nil unless uri

            LlmCostTracker.configuration.openai_compatible_providers[uri.host.to_s.downcase]&.to_s
          end
        end

        def provider_for(request_url)
          self.class.provider_for_uri(parsed_uri(request_url)) || "openai_compatible"
        end
      end
    end
  end
end
