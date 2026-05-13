# frozen_string_literal: true

require_relative "adapter"

module LlmCostTracker
  module Ledger
    module Schema
      module IngestionLeases
        REQUIRED_COLUMNS = %w[
          name
          locked_by
          locked_until
          created_at
          updated_at
        ].freeze

        UNIQUE_COLUMNS = %i[name].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Ingestion::Lease.connection
            Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::Ingestion::Lease.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::Ingestion::Lease.columns_hash
            cache = @schema_capabilities
            return cache.fetch(:errors) if cache && cache.fetch(:columns).equal?(columns)

            errors = compute_errors(connection, table_name, columns)
            @schema_capabilities = { columns: columns, errors: errors }
            errors
          end

          private

          def compute_errors(connection, table_name, columns)
            errors = []
            missing = REQUIRED_COLUMNS - columns.keys
            errors << "missing columns: #{missing.join(', ')}" if missing.any?
            errors << "missing unique index: name" unless name_unique_index?(connection, table_name)
            errors
          end

          def name_unique_index?(connection, table_name)
            connection.index_exists?(table_name, UNIQUE_COLUMNS, unique: true)
          end
        end
      end
    end
  end
end
