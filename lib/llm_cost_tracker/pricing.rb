# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "time"

require_relative "version"
require_relative "token_usage"
require_relative "billing/components"
require_relative "pricing/registry"
require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"
require_relative "pricing/service_charges"

module LlmCostTracker
  module Pricing
    extend ServiceCharges

    STANDARD_MODE_VALUES = %i[auto default standard standard_only].freeze
    RATE_DENOMINATOR_TOKENS = 1_000_000
    private_constant :STANDARD_MODE_VALUES, :RATE_DENOMINATOR_TOKENS

    class << self
      def normalize_mode(value)
        return nil if value.nil?

        mode = value.is_a?(Symbol) ? value : value.strip.presence&.tr("-", "_")&.to_sym
        return nil unless mode

        STANDARD_MODE_VALUES.include?(mode) ? nil : mode
      end

      def cost_for(provider:, model:, tokens:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          tokens: tokens,
          pricing_mode: pricing_mode
        )
        return nil unless calculation

        cost_from(calculation)
      end

      def cost_and_snapshot_for(provider:, model:, tokens:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          tokens: tokens,
          pricing_mode: pricing_mode
        )
        return [nil, nil] unless calculation

        [cost_from(calculation), snapshot_from(calculation)]
      end

      def snapshot_for(provider:, model:, tokens:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          tokens: tokens,
          pricing_mode: pricing_mode
        )
        return nil unless calculation

        snapshot_from(calculation)
      end

      def explain(provider:, model:, tokens:, pricing_mode: nil)
        Explainer.call(
          provider: provider,
          model: model,
          tokens: tokens,
          pricing_mode: pricing_mode
        )
      end

      def stored_cost_attributes(attributes)
        cost_keys = Billing::Components::TOKEN_PRICED.map(&:cost_key) + %i[total_cost]
        attributes = attributes.to_h
        cost_keys.each_with_object({}) do |key, stored|
          value = attributes[key]
          stored[key] = value unless value.nil?
        end
      end

      private

      def cost_from(calculation)
        costs = calculation[:costs]
        values = Billing::Components::TOKEN_PRICED.each_with_object({}) do |component, result|
          cost = costs[component.key]
          result[component.cost_key] = cost.round(8) unless cost.nil?
        end
        values[:total_cost] = costs.values.compact.sum.round(8)
        values
      end

      def snapshot_from(calculation)
        match = calculation[:match]
        effective = calculation[:effective]
        token_usage = calculation[:token_usage]
        rates = Billing::Components::TOKEN_PRICED.each_with_object({}) do |component, values|
          quantity = token_usage.public_send(component.token_key)
          price = effective[component.key]
          next if quantity.zero? || price.nil?

          values[component.key] = {
            amount: price,
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

      def calculation_for(provider:, model:, tokens:, pricing_mode:)
        match = Lookup.call(provider: provider, model: model)
        return nil unless match

        token_usage = TokenUsage.build_from_tokens(tokens)
        mode = normalize_mode(pricing_mode)
        effective = EffectivePrices.call(usage: token_usage, prices: match.prices, pricing_mode: mode)
        return nil unless any_billable_priced?(token_usage, effective)

        { match: match, effective: effective, token_usage: token_usage, costs: costs_for(token_usage, effective) }
      end

      def any_billable_priced?(token_usage, effective)
        billable = Billing::Components::TOKEN_PRICED.select { |c| token_usage.public_send(c.token_key).positive? }
        billable.empty? || billable.any? { |c| effective[c.key] }
      end

      def costs_for(usage, effective)
        Billing::Components::TOKEN_PRICED.to_h do |component|
          tokens = usage.public_send(component.token_key)
          [component.key, token_cost(tokens, effective[component.key])]
        end
      end

      def source_version_for(source)
        case source
        when :bundled
          LlmCostTracker::VERSION
        when :prices_file
          path = LlmCostTracker.configuration.prices_file
          path ? File.mtime(path).utc.iso8601 : nil
        when :pricing_overrides
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
