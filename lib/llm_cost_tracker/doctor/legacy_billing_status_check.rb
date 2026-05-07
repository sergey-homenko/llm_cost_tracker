# frozen_string_literal: true

require_relative "check"
require_relative "probe"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class LegacyBillingStatusCheck
      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")
        return unless LlmCostTracker::Call.column_names.include?("cost_status")

        return unless LlmCostTracker::Call.where(cost_status: nil).exists?

        Check.new(:warn, "cost status", "legacy rows without cost_status remain; new rows will populate it")
      rescue StandardError
        nil
      end
    end
  end
end
