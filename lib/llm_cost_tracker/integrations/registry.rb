# frozen_string_literal: true

require "monitor"

require_relative "../errors"
require_relative "openai"
require_relative "anthropic"
require_relative "ruby_llm"

module LlmCostTracker
  module Integrations
    module Registry
      DEFAULT_INTEGRATIONS = {
        openai: Openai,
        anthropic: Anthropic,
        ruby_llm: RubyLlm
      }.freeze
      MUTEX = Monitor.new

      module_function

      def register(name, integration)
        key = name.to_sym
        validate_integration!(integration)
        MUTEX.synchronize { @integrations = integrations.merge(key => integration).freeze }
        integration
      end

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
        integrations.fetch(name.to_sym) do
          message = "Unknown integration: #{name.inspect}. Use one of: #{names.join(', ')}"
          raise LlmCostTracker::Error, message
        end
      end

      def names
        integrations.keys
      end

      def reset!
        MUTEX.synchronize { @integrations = DEFAULT_INTEGRATIONS.dup.freeze }
      end

      def integrations
        @integrations || MUTEX.synchronize { @integrations ||= DEFAULT_INTEGRATIONS.dup.freeze }
      end

      def validate_integration!(integration)
        return if integration.respond_to?(:install) && integration.respond_to?(:status)

        raise ArgumentError, "integration must respond to install and status"
      end
    end

    def self.register(name, integration) = Registry.register(name, integration)
    def self.install! = Registry.install!
    def self.checks = Registry.checks
  end
end
