# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Isolation
      class << self
        def guard(model = LlmCostTracker::Call, &)
          return yield unless model.connection.transaction_open?

          model.transaction(requires_new: true, &)
        end

        def after_commit(model = LlmCostTracker::Call, &)
          return yield unless model.connection.transaction_open?
          return yield unless ActiveRecord.respond_to?(:after_all_transactions_commit)

          ActiveRecord.after_all_transactions_commit(&)
        end
      end
    end
  end
end
