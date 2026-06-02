# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    Match = Data.define(:source, :key, :prices, :matched_by, :currency)
  end
end
