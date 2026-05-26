# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallRollups
        extend Base

        REQUIRED_COLUMNS = %w[period period_start currency provider total_cost created_at updated_at].freeze

        def self.model = LlmCostTracker::CallRollup
      end
    end
  end
end
