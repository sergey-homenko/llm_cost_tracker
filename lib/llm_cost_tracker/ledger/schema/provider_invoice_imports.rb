# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module ProviderInvoiceImports
        REQUIRED_COLUMNS = %w[
          source provider cursor window_start window_end state last_error
          rows_imported started_at finished_at
        ].freeze
        SOURCE_PROVIDER_STARTED_AT_INDEX = %i[source provider started_at].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::ProviderInvoiceImport.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            errors = []
            errors.concat(column_errors)
            errors.concat(index_errors(connection, table_name))
            errors
          end

          private

          def column_errors
            missing = REQUIRED_COLUMNS - LlmCostTracker::ProviderInvoiceImport.columns_hash.keys
            return [] if missing.empty?

            ["missing columns: #{missing.join(', ')}"]
          end

          def index_errors(connection, table_name)
            return [] if connection.index_exists?(table_name, SOURCE_PROVIDER_STARTED_AT_INDEX)

            ["missing index: source, provider, started_at"]
          end
        end
      end
    end
  end
end
