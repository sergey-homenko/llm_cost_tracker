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

        def compute_errors(connection, table_name, columns)
          column_errors(columns) +
            json_column_errors(connection, columns) +
            foreign_key_errors(connection, table_name)
        end

        def column_errors(columns)
          missing = self::REQUIRED_COLUMNS - columns.keys
          missing.any? ? ["missing columns: #{missing.join(', ')}"] : []
        end

        def json_column_errors(connection, columns)
          return [] unless const_defined?(:JSON_COLUMNS)

          self::JSON_COLUMNS.flat_map do |name|
            Adapter.json_column_errors(columns[name.to_s], connection, name.to_s)
          end
        end

        def foreign_key_errors(connection, table_name)
          return [] unless const_defined?(:FOREIGN_KEYS)

          self::FOREIGN_KEYS.filter_map do |spec|
            next if foreign_key?(connection, table_name, spec)

            "missing foreign key on #{spec[:column]} referencing #{spec[:references]}"
          end
        end

        def foreign_key?(connection, table_name, spec)
          connection.foreign_keys(table_name).any? do |fk|
            fk.column.to_s == spec[:column].to_s &&
              fk.to_table.to_s == spec[:references].to_s
          end
        end
      end
    end
  end
end
