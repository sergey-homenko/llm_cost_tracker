# frozen_string_literal: true

require_relative "section"

module LlmCostTracker
  class Configuration
    class Capture < Section
      OPENAI_COMPATIBLE_PROVIDERS = {
        "openrouter.ai" => "openrouter",
        "api.deepseek.com" => "deepseek",
        "api.groq.com" => "groq"
      }.freeze

      attributes :request_stream_usage

      attr_reader :openai_compatible_providers

      def initialize(owner)
        super
        @request_stream_usage = true
        self.openai_compatible_providers = OPENAI_COMPATIBLE_PROVIDERS
      end

      def openai_compatible_providers=(providers)
        ensure_mutable!
        @openai_compatible_providers = normalize_providers(providers)
      end

      def finalize!
        @openai_compatible_providers = deep_freeze(normalize_providers(@openai_compatible_providers))
      end

      private

      def normalize_providers(providers)
        (providers || {}).each_with_object({}) do |(host, provider), normalized|
          normalized[host.to_s.downcase] = provider.to_s
        end
      end
    end
  end
end
