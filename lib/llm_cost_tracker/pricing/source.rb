# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    Source = Data.define(:name, :prices, :rates, :currency, :version)
  end
end
