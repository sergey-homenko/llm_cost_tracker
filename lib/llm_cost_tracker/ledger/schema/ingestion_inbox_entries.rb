# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module IngestionInboxEntries
        extend Base

        REQUIRED_COLUMNS = %w[
          event_id
          total_cost
          tracked_at
          payload
          locked_at
          locked_by
          attempts
          last_error
          created_at
          updated_at
        ].freeze
        UNIQUE_COLUMNS = %i[event_id].freeze

        class << self
          def model = LlmCostTracker::Ingestion::InboxEntry

          private

          def compute_errors(connection, table_name, columns)
            errors = column_errors(columns)
            unless connection.index_exists?(table_name, UNIQUE_COLUMNS, unique: true)
              errors << "missing unique index: event_id"
            end
            errors
          end
        end
      end
    end
  end
end
