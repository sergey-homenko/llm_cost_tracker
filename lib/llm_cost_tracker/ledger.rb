# frozen_string_literal: true

require_relative "ledger/schema"
require_relative "ledger/period"
require_relative "ledger/rollups"
require_relative "ledger/store"

module LlmCostTracker
  module Ledger
    module Tags
      autoload :Query, "llm_cost_tracker/ledger/tags/query"
      autoload :Breakdown, "llm_cost_tracker/ledger/tags/breakdown"
    end

    module Period
      autoload :Totals, "llm_cost_tracker/ledger/period/totals"
    end
  end
end
