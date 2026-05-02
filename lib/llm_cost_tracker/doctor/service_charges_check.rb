# frozen_string_literal: true

require_relative "check"
require_relative "probe"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class ServiceChargesCheck
      def call
        return unless Probe.table_exists?("llm_api_calls")

        errors = LlmCostTracker::Ledger::Schema::ServiceCharges.current_schema_errors
        return Check.new(:ok, "service charges", "llm_cost_tracker_service_charges exists") if errors.empty?

        Check.new(
          :error,
          "service charges",
          "current schema required; #{errors.join('; ')}; " \
          "run bin/rails generate llm_cost_tracker:add_billing && bin/rails db:migrate"
        )
      end
    end
  end
end
