# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module ProviderInvoiceImports
        extend Base

        REQUIRED_COLUMNS = %w[
          source provider cursor window_start window_end state last_error
          rows_imported started_at finished_at
        ].freeze
        SOURCE_PROVIDER_STARTED_AT_INDEX = %i[source provider started_at].freeze

        class << self
          def model = LlmCostTracker::ProviderInvoiceImport

          private

          def compute_errors(connection, table_name, columns)
            errors = column_errors(columns)
            unless connection.index_exists?(table_name, SOURCE_PROVIDER_STARTED_AT_INDEX)
              errors << "missing index: source, provider, started_at"
            end
            errors
          end
        end
      end
    end
  end
end
