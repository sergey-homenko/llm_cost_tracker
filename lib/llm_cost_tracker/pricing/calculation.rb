# frozen_string_literal: true

require "bigdecimal"

require_relative "../usage/dimension"
require_relative "../charges/line_item"
require_relative "rate"

module LlmCostTracker
  module Pricing
    class Calculation
      RATE_DENOMINATOR_TOKENS = Pricing::RATE_BASIS_QUANTITIES.fetch("per_million_tokens")
      private_constant :RATE_DENOMINATOR_TOKENS

      def self.for(provider:, model:, tokens:, pricing_mode:, line_items: [], usage_source: nil)
        new(provider: provider, model: model, token_usage: Usage::TokenUsage.build_from_tokens(tokens),
            line_items: line_items, mode: Mode.normalize(pricing_mode), usage_source: usage_source)
      end

      def initialize(provider:, model:, token_usage:, line_items:, mode:, usage_source: nil)
        @provider = provider
        @model = model
        @token_usage = token_usage
        @line_items = line_items
        @mode = mode
        @usage_source = usage_source
      end

      attr_reader :mode

      def match
        return @match if defined?(@match)

        @match = Registry.lookup(provider: @provider, model: @model)
      end

      def effective
        return @effective if defined?(@effective)

        @effective = match && EffectivePrices.call(
          usage: @token_usage, quantities: quantities, prices: match.prices, pricing_mode: @mode
        )
      end

      def token_cost
        return @token_cost if defined?(@token_cost)

        @token_cost = priceable? ? build_token_cost : nil
      end

      def priced_line_items
        @priced_line_items ||= unpriced_line_items.map do |line_item|
          line_item.token? ? price_token(line_item) : price_service(line_item)
        end
      end

      def snapshot
        return @snapshot if defined?(@snapshot)

        @snapshot = priceable? ? build_snapshot : nil
      end

      def cost
        return @cost if defined?(@cost)

        @cost = combine_service_lines
      end

      def cost_status
        @cost_status ||= Charges::CostStatus.call(
          token_usage: @token_usage,
          usage_source: @usage_source,
          token_cost: token_cost,
          token_pricing_partial: token_pricing_partial?,
          service_line_items: priced_line_items.reject(&:token?),
          total_cost: cost&.total
        )
      end

      private

      def quantities
        @quantities ||= @token_usage.priced_quantities
      end

      def unpriced_line_items
        Charges::LineItem.from_token_usage(@token_usage) + @line_items
      end

      def priceable?
        !match.nil? && !all_billable_unpriced?
      end

      def all_billable_unpriced?
        any_billable = false
        quantities.each_pair do |key, quantity|
          next unless quantity.positive?
          return false if effective[key]

          any_billable = true
        end
        any_billable
      end

      def priced_token_line_items
        @priced_token_line_items ||= priced_line_items.select(&:token?)
      end

      def build_token_cost
        by_dimension = priced_token_line_items.to_h { |line_item| [line_item.dimension, line_item] }
        components = Usage::Dimension::TOKEN_PRICED.each_with_object({}) do |dimension, result|
          cost = token_dimension_cost(dimension, by_dimension[dimension])
          result[dimension.cost_key] = cost.round(8) unless cost.nil?
        end
        Charges::Cost.new(
          components: components.freeze,
          total: priced_token_line_items.sum(BigDecimal("0"), &:cost_value).round(8),
          currency: match.currency
        )
      end

      def token_dimension_cost(dimension, line_item)
        return BigDecimal("0") if quantities[dimension.key].zero?

        line_item&.cost
      end

      def build_snapshot
        {
          "schema_version" => 1,
          "source" => match.source,
          "source_key" => match.key,
          "source_version" => Pricing.source_version_for(match.source),
          "matched_by" => match.matched_by.to_s,
          "currency" => match.currency,
          "rates" => service_charge_rates.merge(token_charge_rates)
        }
      end

      def token_charge_rates
        priced_token_line_items.each_with_object({}) do |line_item, rates|
          next if line_item.price_key.nil? || line_item.rate_amount.nil?

          rates[line_item.price_key] ||= rate_entry(line_item.rate_amount, line_item.rate_quantity)
        end
      end

      def service_charge_rates
        priced_line_items.each_with_object({}) do |line_item, rates|
          next if line_item.token? || line_item.price_key.nil? || line_item.rate_amount.nil?

          rates[line_item.price_key] ||= rate_entry(line_item.rate_amount, line_item.rate_quantity)
        end
      end

      def rate_entry(amount, quantity)
        { "amount" => BigDecimal(amount.to_s).to_s("F"), "quantity" => Integer(quantity) }
      end

      def price_token(line_item)
        dimension = dimension_for(line_item)
        return line_item unless dimension
        return line_item.with(cost_status: Charges::CostStatus::UNKNOWN) unless priceable?

        price = effective[dimension.key]
        return line_item.with(cost_status: Charges::CostStatus::UNKNOWN) if price.nil?

        line_item.with_rate(token_rate(dimension, price))
      end

      def token_rate(dimension, price)
        Pricing::Rate.new(
          amount: BigDecimal(price.to_s),
          quantity: BigDecimal(RATE_DENOMINATOR_TOKENS),
          currency: match.currency,
          source: match.source,
          source_key: dimension.key,
          source_version: Pricing.source_version_for(match.source)
        )
      end

      def price_service(line_item)
        return line_item if line_item.priced? || !line_item.billable?

        rate = model_rate(line_item) ||
               Registry.charge_rate(provider: @provider, dimension: line_item.kind, pricing_mode: @mode)
        return line_item unless rate

        line_item.with_rate(rate)
      end

      def model_rate(line_item)
        return nil unless priceable?

        amount = match.prices[line_item.kind]
        return nil unless amount.is_a?(Numeric)

        dimension = Usage::Dimension::BY_KEY[line_item.kind]
        Pricing::Rate.new(
          amount: BigDecimal(amount.to_s),
          quantity: BigDecimal(Pricing::RATE_BASIS_QUANTITIES.fetch(dimension.rate_basis).to_s),
          currency: match.currency,
          source: match.source,
          source_key: "#{match.key}.#{line_item.kind}",
          source_version: Pricing.source_version_for(match.source)
        )
      end

      def dimension_for(line_item)
        Usage::Dimension::ALL.find do |dimension|
          dimension.kind == line_item.kind &&
            dimension.direction == line_item.direction &&
            dimension.modality == line_item.modality &&
            dimension.cache_state == line_item.cache_state &&
            dimension.unit == line_item.unit
        end
      end

      def combine_service_lines
        cost = token_cost
        priced_services = priced_line_items.reject(&:token?).select(&:priced?)
        return cost if priced_services.empty?

        base_currency = base_currency_for(cost, priced_services)
        matching, mismatched = priced_services.partition { |line| line.currency.to_s == base_currency.to_s }
        warn_currency_mismatch(mismatched, base_currency) if mismatched.any?

        service_total = matching.sum(BigDecimal("0"), &:cost_value)
        Charges::Cost.new(
          components: cost ? cost.components : {}.freeze,
          total: ((cost&.total || BigDecimal("0")) + service_total).round(8),
          currency: (cost&.currency || base_currency).to_s
        )
      end

      def base_currency_for(cost, priced_services)
        cost&.currency || priced_services.first.currency || LlmCostTracker::DEFAULT_CURRENCY
      end

      def warn_currency_mismatch(lines, base_currency)
        currencies = lines.map { |line| line.currency.to_s }.uniq.sort
        Logging.warn(
          "Service line currency mismatch: header is #{base_currency}, dropping " \
          "#{lines.size} priced line(s) in #{currencies.join(', ')} from header total. " \
          "Per-line costs are still recorded; header total reflects #{base_currency} only."
        )
      end

      def token_pricing_partial?
        return false unless token_cost

        priced_token_line_items.any?(&:unpriced?)
      end
    end
  end
end
