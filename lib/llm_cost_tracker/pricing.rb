# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "time"

require_relative "version"
require_relative "token_usage"
require_relative "billing/cost"
require_relative "pricing/registry"
require_relative "pricing/lookup"
require_relative "pricing/effective_prices"
require_relative "pricing/explanation"
require_relative "pricing/service_charges"
require_relative "pricing/estimator"

module LlmCostTracker
  module Pricing
    RATE_DENOMINATOR_TOKENS = 1_000_000
    private_constant :RATE_DENOMINATOR_TOKENS

    class Calculation
      def self.assess(provider:, model:, tokens:, pricing_mode:)
        new(provider: provider, model: model,
            token_usage: TokenUsage.build_from_tokens(tokens), mode: Mode.normalize(pricing_mode))
      end

      def initialize(provider:, model:, token_usage:, mode:)
        @provider = provider
        @model = model
        @token_usage = token_usage
        @mode = mode
      end

      attr_reader :mode

      def match
        return @match if defined?(@match)

        @match = Lookup.call(provider: @provider, model: @model)
      end

      def quantities
        @quantities ||= @token_usage.priced_quantities
      end

      def effective
        return @effective if defined?(@effective)

        @effective = match && EffectivePrices.call(
          usage: @token_usage, quantities: quantities, prices: match.prices, pricing_mode: @mode
        )
      end

      def costs
        @costs ||= quantities.to_h { |key, tokens| [key, token_cost(tokens, effective[key])] }
      end

      def priceable?
        !match.nil? && !all_billable_unpriced?
      end

      private

      def all_billable_unpriced?
        any_billable = false
        quantities.each_pair do |key, quantity|
          next unless quantity.positive?
          return false if effective[key]

          any_billable = true
        end
        any_billable
      end

      def token_cost(tokens, per_million_price)
        return BigDecimal("0") if tokens.zero?
        return nil if per_million_price.nil?

        (BigDecimal(tokens.to_s) * BigDecimal(per_million_price.to_s)) / RATE_DENOMINATOR_TOKENS
      end
    end
    private_constant :Calculation

    class << self
      def reset_caches!
        Lookup.reset!
        Registry.reset!
        ServiceCharges.reset!
      end

      def cost_for(provider:, model:, tokens:, pricing_mode: nil)
        calculation = Calculation.assess(provider: provider, model: model, tokens: tokens, pricing_mode: pricing_mode)
        return nil unless calculation.priceable?

        cost_from(calculation)
      end

      def calculate(provider:, model:, tokens:, line_items:, pricing_mode: nil)
        calculation = Calculation.assess(provider: provider, model: model, tokens: tokens, pricing_mode: pricing_mode)
        active = calculation if calculation.priceable?
        cost_data = active && cost_from(active)
        priced = apply_calculation_to_line_items(line_items, active,
                                                 provider: provider, pricing_mode: pricing_mode)
        snapshot = active && snapshot_from(active, priced)
        [cost_data, snapshot, priced]
      end

      def explain(provider:, model:, tokens:, pricing_mode: nil)
        calculation = Calculation.assess(provider: provider, model: model, tokens: tokens, pricing_mode: pricing_mode)
        Explanation.from_lookup(
          provider: provider, model: model,
          match: calculation.match, mode: calculation.mode, effective: calculation.effective
        )
      end

      def combine_with_service_lines(cost, line_items)
        priced_services = line_items.reject(&:token?).select(&:priced?)
        return cost if priced_services.empty?

        base_currency = base_currency_for(cost, priced_services)
        matching, mismatched = priced_services.partition { |line| line.currency.to_s == base_currency.to_s }
        warn_currency_mismatch(mismatched, base_currency) if mismatched.any?

        service_total = matching.sum(BigDecimal("0"), &:cost_value)
        Billing::Cost.new(
          components: cost ? cost.components : {}.freeze,
          total: ((cost&.total || BigDecimal("0")) + service_total).round(8),
          currency: (cost&.currency || base_currency).to_s
        )
      end

      def token_pricing_partial?(token_usage, token_cost)
        return false unless token_cost

        token_usage.priced_quantities.any? do |key, quantity|
          next false unless quantity.positive?

          token_cost.components[Billing::Components::BY_KEY.fetch(key).cost_key].nil?
        end
      end

      def source_version_for(source)
        case source
        when "bundled"
          LlmCostTracker::VERSION
        when "prices_file"
          Lookup.prices_file_mtime_iso
        when "pricing_overrides"
          "configuration"
        end
      end

      private

      def base_currency_for(cost, priced_services)
        cost&.currency || priced_services.first.currency || Billing::DEFAULT_CURRENCY
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
        costs = calculation.costs
        components = Billing::Components::TOKEN_PRICED.each_with_object({}) do |component, result|
          cost = costs[component.key]
          result[component.cost_key] = cost.round(8) unless cost.nil?
        end
        Billing::Cost.new(
          components: components.freeze,
          total: costs.values.compact.sum(BigDecimal("0")).round(8),
          currency: calculation.match.currency
        )
      end

      def snapshot_from(calculation, line_items)
        match = calculation.match
        {
          schema_version: 1,
          source: match.source,
          source_key: match.key,
          source_version: source_version_for(match.source),
          matched_by: match.matched_by,
          currency: match.currency,
          rates: service_charge_rates(line_items).merge(token_rates(calculation))
        }
      end

      def token_rates(calculation)
        effective = calculation.effective
        calculation.quantities.each_with_object({}) do |(key, quantity), rates|
          price = effective[key]
          next if quantity.zero? || price.nil?

          rates[key] = { amount: price, quantity: RATE_DENOMINATOR_TOKENS }
        end
      end

      def service_charge_rates(line_items)
        line_items.each_with_object({}) do |line_item, rates|
          next if line_item.token? || line_item.price_key.nil? || line_item.rate_amount.nil?

          rates[line_item.price_key] ||= { amount: line_item.rate_amount, quantity: line_item.rate_quantity }
        end
      end

      def apply_calculation_to_line_items(line_items, calculation, provider:, pricing_mode:)
        line_items.map do |line_item|
          next price_token_line_item(line_item, calculation) if line_item.unit == "token"

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

        effective_price = calculation.effective[component.key]
        return line_item.with(cost_status: Billing::CostStatus::UNKNOWN) if effective_price.nil?

        cost = (line_item.quantity * BigDecimal(effective_price.to_s)) / RATE_DENOMINATOR_TOKENS
        match = calculation.match
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
        return line_item if line_item.priced? || !line_item.billable?

        rate = model_rate_for(line_item, calculation) ||
               ServiceCharges.charge_rate(provider: provider, component: line_item.kind, pricing_mode: pricing_mode)
        return line_item unless rate

        line_item.with_rate(rate)
      end

      def model_rate_for(line_item, calculation)
        return nil unless calculation

        match = calculation.match
        amount = match.prices[line_item.kind]
        return nil unless amount.is_a?(Numeric)

        component = Billing::Components::BY_KEY[line_item.kind]
        Billing::Rate.new(
          amount: BigDecimal(amount.to_s),
          quantity: BigDecimal(Billing::RATE_BASIS_QUANTITIES.fetch(component.rate_basis).to_s),
          currency: match.currency,
          source: match.source,
          source_key: "#{match.key}.#{line_item.kind}",
          source_version: source_version_for(match.source)
        )
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
    end
  end
end
