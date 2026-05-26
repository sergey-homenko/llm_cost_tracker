# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallTags
        extend Base

        REQUIRED_COLUMNS = %w[llm_cost_tracker_call_id key value].freeze

        REQUIRED_INDEXES = [
          { columns: %i[key value] },
          { columns: :llm_cost_tracker_call_id }
        ].freeze

        def self.model = LlmCostTracker::CallTag
      end
    end
  end
end
