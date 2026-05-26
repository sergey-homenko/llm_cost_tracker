# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallTags
        extend Base

        columns :llm_cost_tracker_call_id, :key, :value
      end
    end
  end
end
