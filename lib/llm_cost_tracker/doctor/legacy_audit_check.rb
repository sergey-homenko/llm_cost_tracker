# frozen_string_literal: true

require_relative "check"
require_relative "probe"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class LegacyAuditCheck
      WARNING_PERCENT = 10

      def call
        return unless Probe.table_exists?("llm_api_calls")
        return unless LlmCostTracker::Ledger::Call.column_names.include?("pricing_snapshot")

        counts = LlmCostTracker::Ledger::Call
                 .select(
                   "COUNT(*) AS total_count, " \
                   "COALESCE(SUM(CASE WHEN pricing_snapshot IS NULL THEN 1 ELSE 0 END), 0) AS missing_count"
                 )
                 .take
        total = counts.total_count.to_i
        return if total.zero?

        missing = counts.missing_count.to_i
        return unless (missing * 100) > (total * WARNING_PERCENT)

        message = "#{missing}/#{total} tracked calls lack pricing_snapshot; " \
                  "stored totals remain stable but applied rates cannot be audited"
        Check.new(:warn, "pricing snapshot audit", message)
      rescue StandardError
        nil
      end
    end
  end
end
