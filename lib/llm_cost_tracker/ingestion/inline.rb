# frozen_string_literal: true

require_relative "../ledger/store"

module LlmCostTracker
  module Ingestion
    module Inline
      class << self
        def save(event)
          persist(event)
          event
        end

        private

        def persist(event)
          connection = LlmCostTracker::Call.connection
          if connection.transaction_open?
            persist_with_separate_connection(event)
          else
            Ledger::Store.insert_many([event])
          end
        rescue ActiveRecord::ConnectionTimeoutError => e
          raise LlmCostTracker::Error,
                "ledger inline writer could not checkout a separate database connection: #{e.message}"
        end

        def persist_with_separate_connection(event)
          pool = LlmCostTracker::Call.connection_pool
          connection = pool.checkout
          begin
            connection.transaction(requires_new: true) { Ledger::Store.insert_many([event]) }
          ensure
            pool.checkin(connection)
          end
        end
      end
    end
  end
end
