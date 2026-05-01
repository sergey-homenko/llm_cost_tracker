# frozen_string_literal: true

require_relative "check"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class LegacyBillingStatusCheck
      def call
        return unless table_exists?("llm_api_calls")
        return unless LlmCostTracker::Ledger::Call.column_names.include?("cost_status")

        return unless LlmCostTracker::Ledger::Call.where(cost_status: nil).exists?

        Check.new(:warn, "billing status", "legacy rows without cost_status remain; new rows will populate it")
      rescue StandardError
        nil
      end

      private

      def table_exists?(name)
        LlmCostTracker::Ledger::Call.connection.data_source_exists?(name)
      rescue StandardError
        false
      end
    end
  end
end
