# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module Base
        def model
          @model ||= LlmCostTracker.const_get(detect_model_name)
        end

        def columns(*names)
          @required_columns = names.map(&:to_s).freeze
        end

        def required_columns
          @required_columns || [].freeze
        end

        def current_schema_errors
          connection = model.connection
          Adapter.ensure_supported!(connection)
          table_name = model.table_name
          return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

          columns_hash = model.columns_hash
          cache = @schema_capabilities
          return cache.fetch(:errors) if cache && cache.fetch(:columns).equal?(columns_hash)

          errors = column_errors(columns_hash)
          @schema_capabilities = { columns: columns_hash, errors: errors }
          errors
        end

        private

        def column_errors(columns_hash)
          missing = required_columns - columns_hash.keys
          missing.any? ? ["missing columns: #{missing.join(', ')}"] : []
        end

        def detect_model_name
          name.delete_prefix("#{Schema.name}::").singularize
        end
      end
    end
  end
end
