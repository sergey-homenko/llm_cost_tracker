# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module IngestionLeases
        extend Base

        REQUIRED_COLUMNS = %w[name locked_by locked_until created_at updated_at].freeze
        UNIQUE_COLUMNS = %i[name].freeze

        class << self
          def model = LlmCostTracker::Ingestion::Lease

          private

          def compute_errors(connection, table_name, columns)
            errors = column_errors(columns)
            unless connection.index_exists?(table_name, UNIQUE_COLUMNS, unique: true)
              errors << "missing unique index: name"
            end
            errors
          end
        end
      end
    end
  end
end
