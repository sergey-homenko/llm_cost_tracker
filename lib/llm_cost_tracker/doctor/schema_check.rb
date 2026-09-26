# frozen_string_literal: true

require_relative "../check"
require_relative "probe"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class SchemaCheck
      def initialize(name:, schema:, table:)
        @name = name
        @schema = schema
        @table = table
      end

      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")

        errors = @schema.current_schema_errors
        return Check.new(:ok, @name, "#{@table} exists") if errors.empty?

        Check.new(
          :error,
          @name,
          "current schema required; #{errors.join('; ')}; see docs/upgrading.md"
        )
      end
    end
  end
end
