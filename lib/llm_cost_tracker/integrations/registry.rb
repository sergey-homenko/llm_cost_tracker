# frozen_string_literal: true

require_relative "openai"
require_relative "anthropic"

module LlmCostTracker
  module Integrations
    module Registry
      INTEGRATIONS = {
        openai: Openai,
        anthropic: Anthropic
      }.freeze

      module_function

      def install!(names = LlmCostTracker.configuration.instrumented_integrations)
        normalize(names).each { |name| fetch(name).install }
      end

      def checks(names = LlmCostTracker.configuration.instrumented_integrations)
        return [Base::Result.new(:integrations, :ok, "no SDK integrations enabled")] if names.empty?

        normalize(names).map { |name| fetch(name).status }
      end

      def normalize(names)
        Array(names).flatten.map(&:to_sym).uniq
      end

      def fetch(name)
        INTEGRATIONS.fetch(name.to_sym) do
          message = "Unknown integration: #{name.inspect}. Use one of: #{INTEGRATIONS.keys.join(', ')}"
          raise LlmCostTracker::Error, message
        end
      end
    end

    def self.install! = Registry.install!
    def self.checks = Registry.checks
  end
end
