# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "time"

require_relative "version"
require_relative "usage/token_usage"
require_relative "charges/cost"
require_relative "charges/cost_status"
require_relative "pricing/price_key"
require_relative "pricing/registry"
require_relative "pricing/source"
require_relative "pricing/matcher"
require_relative "pricing/service_rates"
require_relative "pricing/effective_prices"
require_relative "pricing/estimator"
require_relative "pricing/calculation"

module LlmCostTracker
  module Pricing
    class << self
      def cost_for(provider:, model:, tokens:, pricing_mode: nil)
        Calculation.for(provider: provider, model: model, tokens: tokens, pricing_mode: pricing_mode).token_cost
      end
    end
  end
end
