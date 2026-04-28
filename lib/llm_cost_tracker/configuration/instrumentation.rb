# frozen_string_literal: true

module LlmCostTracker
  module ConfigurationInstrumentation
    def instrument(*names)
      ensure_shared_configuration_mutable!
      @instrumented_integrations = (@instrumented_integrations + normalize_instrumentation_names(names)).uniq
    end

    def instrumented?(name)
      @instrumented_integrations.include?(name.to_sym)
    end

    private

    def normalize_instrumentation_names(names)
      names.flatten.flat_map do |name|
        key = name.to_sym
        next available_instrumentation_names if key == :all

        validate_instrumentation_name!(key)
        key
      end
    end

    def validate_instrumentation_name!(name)
      return if available_instrumentation_names.include?(name)

      raise Error, "Unknown integration: #{name.inspect}. " \
                   "Use one of: #{available_instrumentation_names.join(', ')}"
    end

    def available_instrumentation_names
      Integrations::Registry.names
    end
  end
end
