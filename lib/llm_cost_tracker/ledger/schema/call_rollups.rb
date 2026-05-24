# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallRollups
        extend Base

        REQUIRED_COLUMNS = %w[period period_start currency provider total_cost created_at updated_at].freeze
        UNIQUE_COLUMNS = %i[period period_start currency provider].freeze

        class << self
          def model = LlmCostTracker::CallRollup

          private

          def compute_errors(connection, table_name, columns)
            errors = column_errors(columns)
            unless connection.index_exists?(table_name, UNIQUE_COLUMNS, unique: true)
              errors << "missing unique index: period, period_start, currency, provider"
            end
            errors
          end
        end
      end
    end
  end
end
