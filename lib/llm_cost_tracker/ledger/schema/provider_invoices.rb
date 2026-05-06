# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Schema
      module ProviderInvoices
        REQUIRED_COLUMNS = %w[
          source period_start period_end external_id billed_amount currency metadata imported_at
        ].freeze

        class << self
          def current_schema_errors
            connection = LlmCostTracker::Call.connection
            Ledger::Schema::Adapter.ensure_supported!(connection)
            table_name = LlmCostTracker::ProviderInvoice.table_name
            return ["#{table_name} table is missing"] unless connection.data_source_exists?(table_name)

            columns = LlmCostTracker::ProviderInvoice.columns_hash
            missing = REQUIRED_COLUMNS - columns.keys
            return [] if missing.empty?

            ["missing columns: #{missing.join(', ')}"]
          end
        end
      end
    end
  end
end
