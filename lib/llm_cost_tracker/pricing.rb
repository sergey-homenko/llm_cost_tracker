# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "time"

require_relative "version"
require_relative "pricing/registry"
require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explainer"
require_relative "pricing/service_charges"
require_relative "pricing/estimator"

module LlmCostTracker
  module Pricing
    extend ServiceCharges

    RATE_DENOMINATOR_TOKENS = 1_000_000
    private_constant :RATE_DENOMINATOR_TOKENS

    class << self
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

      def combine_with_service_lines(cost_data, line_items)
        priced_services = line_items.reject(&:token?).select(&:priced?)
        return cost_data if priced_services.empty?

        base_currency = base_currency_for(cost_data, priced_services)
        matching, mismatched = priced_services.partition { |line| line.currency.to_s == base_currency.to_s }
        warn_currency_mismatch(mismatched, base_currency) if mismatched.any?

        cost = cost_data ? cost_data.dup : {}
        cost[:currency] ||= base_currency.to_s
        return cost if matching.empty?

        service_total = matching.sum(BigDecimal("0"), &:cost_value)
        base_total = BigDecimal(cost.fetch(:total_cost, 0).to_s)
        cost[:total_cost] = (base_total + service_total).round(8)
        cost
      end

      def token_pricing_partial?(token_usage, cost_data)
        return false unless cost_data

        token_usage.priced_quantities.any? do |key, quantity|
          next false unless quantity.positive?

          cost_data[Billing::Components::BY_KEY.fetch(key).cost_key].nil?
        end
      end

      private

      def base_currency_for(cost_data, priced_services)
        (cost_data && cost_data[:currency]) || priced_services.first.currency || Billing::LineItem::USD
      end

      def warn_currency_mismatch(lines, base_currency)
        currencies = lines.map { |line| line.currency.to_s }.uniq.sort
        Logging.warn(
          "Service line currency mismatch: header is #{base_currency}, dropping " \
          "#{lines.size} priced line(s) in #{currencies.join(', ')} from header total. " \
          "Per-line costs are still recorded; header total reflects #{base_currency} only."
        )
      end

      def cost_from(calculation)
        costs = calculation[:costs]
        values = Billing::Components::TOKEN_PRICED.each_with_object({}) do |component, result|
          cost = costs[component.key]
          result[component.cost_key] = cost.round(8) unless cost.nil?
        end
        values[:total_cost] = costs.values.compact.sum(BigDecimal("0")).round(8)
        values[:currency] = calculation[:match].currency
        values
      end

      def snapshot_from(calculation)
        match = calculation[:match]
        effective = calculation[:effective]
        rates = calculation[:quantities].each_with_object({}) do |(key, quantity), values|
          price = effective[key]
          next if quantity.zero? || price.nil?

          values[key] = { amount: price, quantity: RATE_DENOMINATOR_TOKENS }
        end

        {
          schema_version: 1,
          source: match.source,
          source_key: match.key,
          source_version: source_version_for(match.source),
          matched_by: match.matched_by,
          currency: match.currency,
          rates: rates
        }
      end

      def calculation_for(provider:, model:, tokens:, pricing_mode:)
        match = Lookup.call(provider: provider, model: model)
        return nil unless match

        token_usage = TokenUsage.build_from_tokens(tokens)
        quantities = token_usage.priced_quantities
        mode = Mode.normalize(pricing_mode)
        effective = EffectivePrices.call(usage: token_usage, quantities: quantities, prices: match.prices,
                                         pricing_mode: mode)
        return nil unless any_billable_priced?(quantities, effective)

        { match: match, effective: effective, token_usage: token_usage, quantities: quantities,
          costs: costs_for(quantities, effective) }
      end

      def any_billable_priced?(quantities, effective)
        any_billable = false
        quantities.each_pair do |key, quantity|
          next unless quantity.positive?
          return true if effective[key]

          any_billable = true
        end
        !any_billable
      end

      def costs_for(quantities, effective)
        quantities.to_h { |key, tokens| [key, token_cost(tokens, effective[key])] }
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
          currency: match.currency,
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

        line_item.with_rate(rate)
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
          currency: match.currency,
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
          Lookup.prices_file_mtime_iso
        when :pricing_overrides
          "configuration"
        end
      end

      def token_cost(tokens, per_million_price)
        return BigDecimal("0") if tokens.zero?
        return nil if per_million_price.nil?

        (BigDecimal(tokens.to_s) * BigDecimal(per_million_price.to_s)) / RATE_DENOMINATOR_TOKENS
      end
    end
  end
end
