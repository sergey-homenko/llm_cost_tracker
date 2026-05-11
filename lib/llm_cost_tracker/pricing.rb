# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "time"

require_relative "version"
require_relative "token_usage"
require_relative "billing/components"
require_relative "pricing/mode"
require_relative "pricing/registry"
require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"
require_relative "pricing/service_charges"

module LlmCostTracker
  module Pricing # rubocop:disable Metrics/ModuleLength
    extend ServiceCharges

    STANDARD_MODE_VALUES = %i[auto default standard standard_only].freeze
    RATE_DENOMINATOR_TOKENS = 1_000_000
    private_constant :STANDARD_MODE_VALUES, :RATE_DENOMINATOR_TOKENS

    class << self
      def normalize_mode(value)
        return nil if value.nil?

        mode = normalize_string_mode(value.to_s)
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

      def calculate(provider:, model:, tokens:, line_items:, pricing_mode: nil)
        calculation = calculation_for(
          provider: provider,
          model: model,
          tokens: tokens,
          pricing_mode: pricing_mode
        )
        cost_data = calculation && cost_from(calculation)
        snapshot = calculation && snapshot_from(calculation)
        priced = apply_calculation_to_line_items(line_items, calculation,
                                                 provider: provider, pricing_mode: pricing_mode)
        [cost_data, snapshot, priced]
      end

      def price_line_items(provider:, model:, line_items:, pricing_mode: nil)
        token_usage = TokenUsage.build_from_tokens(token_attributes_from(line_items))
        calculation = calculation_for(provider: provider, model: model, tokens: token_usage, pricing_mode: pricing_mode)
        snapshot = calculation && snapshot_from(calculation)
        priced = apply_calculation_to_line_items(line_items, calculation,
                                                 provider: provider, pricing_mode: pricing_mode)
        [priced, snapshot]
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
        value = attributes.to_h[:total_cost]
        value ? { total_cost: value } : {}
      end

      private

      def normalize_string_mode(value)
        normalized = value.strip
        return nil if normalized.empty?

        normalized.downcase.tr("-", "_").to_sym
      end

      def cost_from(calculation)
        costs = calculation[:costs]
        values = Billing::Components::TOKEN_PRICED.each_with_object({}) do |component, result|
          cost = costs[component.key]
          result[component.cost_key] = cost.round(8) unless cost.nil?
        end
        values[:total_cost] = costs.values.compact.sum(BigDecimal("0")).round(8)
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

      def apply_calculation_to_line_items(line_items, calculation, provider:, pricing_mode:)
        line_items.map do |line_item|
          next price_token_line_item(line_item, calculation) if line_item.unit == :token

          price_service_charge_line_item(line_item,
                                         provider: provider,
                                         calculation: calculation,
                                         pricing_mode: pricing_mode)
        end
      end

      def token_attributes_from(line_items)
        line_items.each_with_object({}) do |line_item, totals|
          next unless line_item.unit == :token

          component = component_for_line_item(line_item)
          next unless component

          totals[component.key] = (totals[component.key] || 0) + line_item.quantity.to_i
        end
      end

      def price_token_line_item(line_item, calculation)
        component = component_for_line_item(line_item)
        return line_item unless component
        return line_item.with(cost_status: Billing::CostStatus::UNKNOWN) unless calculation

        effective_price = calculation[:effective][component.key]
        return line_item.with(cost_status: Billing::CostStatus::UNKNOWN) if effective_price.nil?

        cost = (line_item.quantity * BigDecimal(effective_price.to_s)) / RATE_DENOMINATOR_TOKENS
        match = calculation[:match]
        line_item.with(
          rate_amount: BigDecimal(effective_price.to_s),
          rate_quantity: BigDecimal(RATE_DENOMINATOR_TOKENS),
          cost: cost,
          cost_status: cost.zero? ? Billing::CostStatus::FREE : Billing::CostStatus::COMPLETE,
          price_key: component.key,
          price_source: match.source,
          price_source_version: source_version_for(match.source)
        )
      end

      def price_service_charge_line_item(line_item, provider:, calculation:, pricing_mode:)
        return line_item if line_item.priced?
        return line_item unless line_item.billable?

        rate = model_rate_for(line_item, calculation) ||
               charge_rate(provider: provider, component: line_item.kind, pricing_mode: pricing_mode)
        return line_item unless rate

        line_item.apply_rate(rate)
      end

      def model_rate_for(line_item, calculation)
        return nil unless calculation

        match = calculation[:match]
        amount = match.prices[line_item.kind] || match.prices[line_item.kind.to_s]
        return nil unless amount.is_a?(Numeric)

        component = Billing::Components::BY_KEY[line_item.kind]
        {
          amount: BigDecimal(amount.to_s),
          quantity: BigDecimal(Billing::RATE_BASIS_QUANTITIES.fetch(component.rate_basis).to_s),
          currency: "USD",
          source: match.source,
          source_key: "#{match.key}.#{line_item.kind}",
          source_version: source_version_for(match.source)
        }
      end

      def component_for_line_item(line_item)
        Billing::Components::REGISTRY.find do |component|
          component.kind == line_item.kind &&
            component.direction == line_item.direction &&
            component.modality == line_item.modality &&
            component.cache_state == line_item.cache_state &&
            component.unit == line_item.unit
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
        return BigDecimal("0") if tokens.zero?
        return nil if per_million_price.nil?

        (BigDecimal(tokens.to_s) * BigDecimal(per_million_price.to_s)) / RATE_DENOMINATOR_TOKENS
      end
    end
  end
end
