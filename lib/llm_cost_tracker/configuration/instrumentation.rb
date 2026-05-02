# frozen_string_literal: true

module LlmCostTracker
  module ConfigurationInstrumentation
    def instrument(*names)
      ensure_shared_configuration_mutable!
      @instrumented_integrations = (@instrumented_integrations + normalize_instrumentation_names(names)).uniq
    end

    def instrumented?(name)
      @instrumented_integrations.include?(name)
    end

    private

    def normalize_instrumentation_names(names)
      names.flatten.flat_map do |name|
        next Integrations.names if name == :all

        validate_instrumentation_name!(name)
        name
      end
    end

    def validate_instrumentation_name!(name)
      return if Integrations.names.include?(name)

      raise Error, "Unknown integration: #{name.inspect}. " \
                   "Use one of: #{Integrations.names.join(', ')}"
    end
  end
end
