# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "time"

require_relative "version"
require_relative "token_usage"
require_relative "billing/cost"
require_relative "billing/cost_status"
require_relative "billing/line_item"
require_relative "pricing/registry"
require_relative "pricing/effective_prices"
require_relative "pricing/estimator"
require_relative "pricing/calculation"

module LlmCostTracker
  module Pricing
    class << self
      def cost_for(provider:, model:, tokens:, pricing_mode: nil)
        token_usage = TokenUsage.build_from_tokens(tokens)
        Calculation.for(
          provider: provider, model: model, tokens: token_usage, pricing_mode: pricing_mode,
          line_items: Billing::LineItem.from_token_usage(token_usage)
        ).token_cost
      end

      def source_version_for(source)
        case source
        when "bundled"
          LlmCostTracker::VERSION
        when "prices_file"
          Registry.prices_file_mtime_iso
        when "pricing_overrides"
          "configuration"
        end
      end
    end
  end
end
