# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module ProviderInvoices
        REQUIRED_COLUMNS = %w[
          source period_start period_end external_id billed_amount currency metadata imported_at
        ].freeze
        UNIQUE_INDEX_COLUMNS = %i[external_id].freeze
        SOURCE_PERIOD_INDEX_COLUMNS = %i[source period_start].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::ProviderInvoice.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            errors = []
            errors.concat(column_errors)
            errors.concat(metadata_type_errors(connection))
            errors.concat(index_errors(connection, table_name))
            errors
          end

          private

          def column_errors
            missing = REQUIRED_COLUMNS - LlmCostTracker::ProviderInvoice.columns_hash.keys
            return [] if missing.empty?

            ["missing columns: #{missing.join(', ')}"]
          end

          def metadata_type_errors(connection)
            metadata = LlmCostTracker::ProviderInvoice.columns_hash["metadata"]
            return [] unless metadata

            expected = Adapter.postgresql?(connection) ? "jsonb" : "json"
            return [] if metadata.sql_type.to_s.start_with?(expected)

            ["metadata column must be #{expected} (got #{metadata.sql_type})"]
          end

          def index_errors(connection, table_name)
            errors = []
            unless connection.index_exists?(table_name, UNIQUE_INDEX_COLUMNS, unique: true)
              errors << "missing unique index: external_id"
            end
            unless connection.index_exists?(table_name, SOURCE_PERIOD_INDEX_COLUMNS)
              errors << "missing index: source, period_start"
            end
            errors
          end
        end
      end
    end
  end
end
