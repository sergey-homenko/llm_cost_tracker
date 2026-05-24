# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module Base
        def current_schema_errors
          connection = model.connection
          Adapter.ensure_supported!(connection)
          table_name = model.table_name
          return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

          columns = model.columns_hash
          cache = @schema_capabilities
          return cache.fetch(:errors) if cache && cache.fetch(:columns).equal?(columns)

          errors = compute_errors(connection, table_name, columns)
          @schema_capabilities = { columns: columns, errors: errors }
          errors
        end

        private

        def column_errors(columns)
          missing = self::REQUIRED_COLUMNS - columns.keys
          missing.any? ? ["missing columns: #{missing.join(', ')}"] : []
        end
      end
    end
  end
end
