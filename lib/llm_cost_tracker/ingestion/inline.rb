# frozen_string_literal: true

require_relative "../ledger/store"

module LlmCostTracker
  module Ingestion
    module Inline
      class << self
        def save(event)
          Ledger::Store.insert_many([event], skip_existence_check: true)
          event
        end
      end
    end
  end
end
