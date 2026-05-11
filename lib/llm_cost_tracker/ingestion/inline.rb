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
          Ledger::Store.insert_many([event])
        end
      end
    end
  end
end
