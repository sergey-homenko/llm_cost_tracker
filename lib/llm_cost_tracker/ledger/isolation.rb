# frozen_string_literal: true

require_relative "../errors"

module LlmCostTracker
  module Ledger
    module Isolation
      class << self
        def guard(model = LlmCostTracker::Call, &)
          isolate(model, standalone: false, &)
        end

        def transaction(model = LlmCostTracker::Call, &)
          isolate(model, standalone: true, &)
        end

        def after_commit(model = LlmCostTracker::Call, &)
          current = model.connection.current_transaction
          return yield unless current.open? && current.joinable? && current.respond_to?(:after_commit)

          current.after_commit(&)
        end

        private

        def isolate(model, standalone:, &)
          connection = model.connection
          nested = connection.transaction_open?
          return model.transaction(requires_new: true, &) if nested
          return model.transaction(&) if standalone

          yield
        rescue ActiveRecord::TransactionRollbackError => e
          raise unless nested && invalidates_transaction?(connection)

          raise TransactionAbortedError, e
        end

        def invalidates_transaction?(connection)
          connection.respond_to?(:savepoint_errors_invalidate_transactions?) &&
            connection.savepoint_errors_invalidate_transactions?
        end
      end
    end
  end
end
