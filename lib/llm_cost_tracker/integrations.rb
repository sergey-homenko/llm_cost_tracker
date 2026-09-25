# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require_relative "check"
require_relative "errors"

module LlmCostTracker
  module Integrations
    autoload :Base, "llm_cost_tracker/integrations/base"

    Dir.glob(File.join(__dir__, "integrations", "*.rb")).each do |path|
      basename = File.basename(path, ".rb")
      next if basename == "base"

      autoload basename.camelize.to_sym, "llm_cost_tracker/integrations/#{basename}"
    end

    def self.install!(names = LlmCostTracker.configuration.instrumented_integrations)
      normalize(names).each do |name|
        integration = fetch(name)
        next integration.install if integration

        Logging.warn("Unknown integration: #{name.inspect}. Known: #{self.names.map(&:inspect).join(', ')}")
      end
    end

    def self.checks(names = LlmCostTracker.configuration.instrumented_integrations)
      return [Check.new(:ok, "integrations", "no SDK integrations enabled")] if names.empty?

      normalize(names).map do |name|
        integration = fetch(name)
        next integration.status if integration

        Check.new(:warn, name.to_s, "unknown integration; check your config.instrument(...) call")
      end
    end

    def self.normalize(names)
      Array(names).flatten.uniq
    end

    def self.fetch(name)
      const_name = name.to_s.camelize
      return nil unless const_name.match?(/\A[A-Z]\w*\z/)
      return nil unless const_defined?(const_name, false)

      const_get(const_name, false)
    end

    def self.names
      constants(false).reject { |c| c == :Base }.map { |c| c.to_s.underscore.to_sym }.sort
    end
  end
end
