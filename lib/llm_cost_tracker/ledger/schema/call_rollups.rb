# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module CallRollups
        REQUIRED_COLUMNS = %w[period period_start currency provider total_cost].freeze
        UNIQUE_COLUMNS = %i[period period_start currency provider].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::CallRollup.connection
            Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::CallRollup.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            errors = []
            missing = REQUIRED_COLUMNS - LlmCostTracker::CallRollup.columns_hash.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            unless unique_period_index?(connection, table_name)
              errors << "missing unique index: period, period_start, currency, provider"
            end
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
