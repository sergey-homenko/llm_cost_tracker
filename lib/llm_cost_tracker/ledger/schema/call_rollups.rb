# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallRollups
        extend Base

        columns :period, :period_start, :currency, :provider, :total_cost, :created_at, :updated_at
      end
    end
  end
end
