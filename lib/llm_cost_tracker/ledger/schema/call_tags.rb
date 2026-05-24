# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallTags
        extend Base

        REQUIRED_COLUMNS = %w[llm_cost_tracker_call_id key value].freeze
        REQUIRED_INDEX_COLUMNS = [
          %w[key value],
          %w[llm_cost_tracker_call_id]
        ].freeze

        class << self
          def model = LlmCostTracker::CallTag

          private

          def compute_errors(connection, table_name, columns)
            column_errors(columns) + missing_index_errors(connection, table_name)
          end

          def missing_index_errors(connection, table_name)
            existing = connection.indexes(table_name).map { |index| Array(index.columns).map(&:to_s) }
            REQUIRED_INDEX_COLUMNS.filter_map do |required|
              next if existing.any? { |columns| (required - columns).empty? }

              "missing index on (#{required.join(', ')})"
            end
          end
        end
      end
    end
  end
end
