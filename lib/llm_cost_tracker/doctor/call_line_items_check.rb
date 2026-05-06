# frozen_string_literal: true

require_relative "check"
require_relative "probe"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class CallLineItemsCheck
      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")

        errors = LlmCostTracker::Ledger::Schema::CallLineItems.current_schema_errors
        return Check.new(:ok, "call line items", "llm_cost_tracker_call_line_items exists") if errors.empty?

        Check.new(
          :error,
          "call line items",
          "current schema required; #{errors.join('; ')}; " \
          "run bin/rails generate llm_cost_tracker:install && bin/rails db:migrate"
        )
      end
    end
  end
end
