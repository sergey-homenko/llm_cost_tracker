# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Schema
      module PeriodTotals
        REQUIRED_COLUMNS = %w[period period_start total_cost].freeze
        UNIQUE_COLUMNS = %i[period period_start].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            table_name = LlmCostTracker::PeriodTotal.table_name
            return ["llm_cost_tracker_period_totals table is missing"] unless connection.data_source_exists?(table_name)

            errors = []
            missing = REQUIRED_COLUMNS - LlmCostTracker::PeriodTotal.columns_hash.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors << "missing unique index: period, period_start" unless unique_period_index?(connection, table_name)
            errors
          end

          private

          def unique_period_index?(connection, table_name)
            connection.index_exists?(table_name, UNIQUE_COLUMNS, unique: true)
          end
        end
      end
    end
  end
end
