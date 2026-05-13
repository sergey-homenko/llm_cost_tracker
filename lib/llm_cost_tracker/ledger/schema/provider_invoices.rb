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
        SOURCE_PERIOD_INDEX_COLUMNS = %i[source currency period_start].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::ProviderInvoice.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::ProviderInvoice.columns_hash
            cache = @schema_capabilities
            return cache.fetch(:errors) if cache && cache.fetch(:columns).equal?(columns)

            errors = compute_errors(connection, table_name, columns)
            @schema_capabilities = { columns: columns, errors: errors }
            errors
          end

          private

          def compute_errors(connection, table_name, columns)
            errors = []
            errors.concat(column_errors(columns))
            errors.concat(Adapter.json_column_errors(columns["metadata"], connection, "metadata"))
            errors.concat(index_errors(connection, table_name))
            errors
          end

          def column_errors(columns)
            missing = REQUIRED_COLUMNS - columns.keys
            return [] if missing.empty?

            ["missing columns: #{missing.join(', ')}"]
          end

          def index_errors(connection, table_name)
            errors = []
            unless connection.index_exists?(table_name, UNIQUE_INDEX_COLUMNS, unique: true)
              errors << "missing unique index: external_id"
            end
            unless connection.index_exists?(table_name, SOURCE_PERIOD_INDEX_COLUMNS)
              errors << "missing index: source, currency, period_start"
            end
            errors
          end
        end
      end
    end
  end
end
