# frozen_string_literal: true

require_relative "../errors"

module LlmCostTracker
  module Ledger
    module Isolation
      class << self
        def guard(model = LlmCostTracker::Call, &)
          connection = model.connection
          nested = connection.transaction_open?
          return yield unless nested

          model.transaction(requires_new: true, &)
        rescue ActiveRecord::TransactionRollbackError => e
          raise unless nested && connection.savepoint_errors_invalidate_transactions?

          raise TransactionAbortedError, e
        end

        def after_commit(&)
          current = LlmCostTracker::Call.connection.current_transaction
          return yield unless current.open? && current.joinable? && current.respond_to?(:after_commit)

          current.after_commit(&)
        end
      end
    end
  end
end
