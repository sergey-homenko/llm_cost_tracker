# frozen_string_literal: true

require "active_support/core_ext/hash/keys"
require "active_support/core_ext/object/blank"
require "time"

require_relative "version"
require_relative "billing/components"
require_relative "pricing/registry"
require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"
require_relative "pricing/service_charges"

module LlmCostTracker
  module Pricing
    extend ServiceCharges

    STANDARD_MODE_VALUES = %w[auto default standard standard_only].freeze
    RATE_DENOMINATOR_TOKENS = 1_000_000
    private_constant :STANDARD_MODE_VALUES, :RATE_DENOMINATOR_TOKENS

    class << self
      def normalize_mode(value)
        mode = value.to_s.strip.presence
        return nil unless mode

        mode = mode.tr("-", "_")
        STANDARD_MODE_VALUES.include?(mode) ? nil : mode
      end

      def cost_for(provider:, model:, token_usage:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode
        )
        return nil unless calculation

        cost_from(calculation)
      end

      def lookup(provider:, model:)
        Lookup.call(provider: provider, model: model)&.prices
      end

      def cost_and_snapshot_for(provider:, model:, token_usage:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode
        )
        return [nil, nil] unless calculation

        [cost_from(calculation), snapshot_from(calculation, token_usage)]
      end

      def snapshot_for(provider:, model:, token_usage:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode
        )
        return nil unless calculation

        snapshot_from(calculation, token_usage)
      end

      def explain(provider:, model:, token_usage:, pricing_mode: nil)
        Explainer.call(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode
        )
      end

      def stored_cost_attributes(attributes)
        cost_keys = Billing::Components::TOKEN_PRICED.map(&:cost_key) + %i[total_cost]
        attributes.to_h.symbolize_keys.slice(*cost_keys).compact
      end

      private

      def cost_from(calculation)
        costs = calculation[:costs]
        values = Billing::Components::TOKEN_PRICED.to_h do |component|
          [component.cost_key, costs[component.key].round(8)]
        end

        values.merge(total_cost: costs.values.sum.round(8))
      end

      def snapshot_from(calculation, token_usage)
        match = calculation[:match]
        effective = calculation[:effective]
        quantities = token_usage.price_quantities
        rates = Billing::Components::TOKEN_PRICED.each_with_object({}) do |component, values|
          quantity = quantities[component.key]
          next unless quantity.positive?

          values[component.key] = {
            amount: effective[component.key],
            quantity: RATE_DENOMINATOR_TOKENS
          }
        end

        {
          schema_version: 1,
          source: match.source,
          source_key: match.key,
          source_version: source_version_for(match.source),
          matched_by: match.matched_by,
          currency: "USD",
          rates: rates
        }
      end

      def calculation_for(provider:, model:, token_usage:, pricing_mode:)
        match = Lookup.call(provider: provider, model: model)
        return nil unless match

        effective = EffectivePrices.call(usage: token_usage, prices: match.prices, pricing_mode: pricing_mode)
        return nil if effective.value?(nil)

        {
          match: match,
          effective: effective,
          costs: costs_for(token_usage, effective)
        }
      end

      def costs_for(usage, effective)
        usage.price_quantities.to_h do |key, tokens|
          [key, token_cost(tokens, effective[key])]
        end
      end

      def source_version_for(source)
        case source.to_s
        when "bundled"
          LlmCostTracker::VERSION
        when "prices_file"
          path = LlmCostTracker.configuration.prices_file
          path ? File.mtime(path).utc.iso8601 : nil
        when "pricing_overrides"
          "configuration"
        end
      rescue Errno::ENOENT
        nil
      end

      def token_cost(tokens, per_million_price)
        return 0.0 if tokens.zero?
        return nil if per_million_price.nil?

        (tokens * per_million_price) / RATE_DENOMINATOR_TOKENS
      end
    end
  end
end
