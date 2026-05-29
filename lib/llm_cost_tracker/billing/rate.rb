# frozen_string_literal: true

module LlmCostTracker
  module Billing
    Rate = Data.define(:amount, :quantity, :currency, :source, :source_key, :source_version)
  end
end
