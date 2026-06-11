# frozen_string_literal: true

require "bigdecimal/util"

require_relative "../usage/catalog"
require_relative "../charges/line_item"
require_relative "rate"

module LlmCostTracker
  module Pricing
    class Calculation
      RATE_DENOMINATOR_TOKENS = Pricing::RATE_BASIS_QUANTITIES.fetch("per_million_tokens")
      SNAPSHOT_SCHEMA_VERSION = 1
      private_constant :RATE_DENOMINATOR_TOKENS, :SNAPSHOT_SCHEMA_VERSION

      def self.for(provider:, model:, tokens:, pricing_mode:, line_items: [], usage_source: nil)
        new(provider: provider,
            model: model,
            token_usage: Usage::TokenUsage.build_from_tokens(tokens),
            line_items: line_items,
            mode: Mode.normalize(pricing_mode),
            usage_source: usage_source)
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

        @match = Matcher.lookup(provider: @provider, model: @model)
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

        @snapshot =
          if priceable?
            build_snapshot
          elsif kept_service_lines.any?
            build_service_snapshot
          end
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
        Charges::LineItem.from_token_usage(@token_usage) + @line_items.reject(&:token?)
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
        components = Usage::Catalog.token_priced.each_with_object({}) do |dimension, result|
          cost = token_dimension_cost(dimension, by_dimension[dimension])
          result[dimension.cost_key] = cost.round(8) unless cost.nil?
        end
        Charges::Cost.new(
          components: components.freeze,
          total: priced_token_line_items.sum(BigDecimal("0")) { |line_item| line_item.cost_value.round(8) },
          currency: match.source.currency
        )
      end

      def token_dimension_cost(dimension, line_item)
        return BigDecimal("0") if quantities[dimension.key].zero?

        line_item&.cost
      end

      def build_snapshot
        {
          "schema_version" => SNAPSHOT_SCHEMA_VERSION,
          "source" => match.source.name,
          "source_key" => match.key,
          "source_version" => match.source.version,
          "matched_by" => match.matched_by.to_s,
          "currency" => match.source.currency,
          "rates" => service_charge_rates.merge(token_charge_rates)
        }
      end

      def build_service_snapshot
        primary = kept_service_lines.first
        {
          "schema_version" => SNAPSHOT_SCHEMA_VERSION,
          "source" => primary.price_source,
          "source_version" => primary.price_source_version,
          "matched_by" => "service_charges",
          "currency" => cost.currency,
          "rates" => service_charge_rates
        }
      end

      def token_charge_rates
        priced_token_line_items.each_with_object({}) do |line_item, rates|
          next if line_item.price_key.nil? || line_item.rate_amount.nil?

          rates[line_item.price_key] ||= rate_entry(line_item.rate_amount, line_item.rate_quantity)
        end
      end

      def service_charge_rates
        kept_service_lines.each_with_object({}) do |line_item, rates|
          next if line_item.price_key.nil? || line_item.rate_amount.nil?

          rates[line_item.price_key] ||= rate_entry(line_item.rate_amount, line_item.rate_quantity)
        end
      end

      def rate_entry(amount, quantity)
        { "amount" => amount.to_d.to_s("F"), "quantity" => Integer(quantity) }
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
          amount: price.to_d,
          quantity: RATE_DENOMINATOR_TOKENS.to_d,
          currency: match.source.currency,
          source: match.source.name,
          source_key: dimension.key,
          source_version: match.source.version
        )
      end

      def price_service(line_item)
        return line_item if line_item.priced? || !line_item.billable?

        rate = model_rate(line_item) ||
               ServiceRates.charge_rate(provider: @provider, dimension: line_item.kind, pricing_mode: @mode)
        return line_item unless rate

        line_item.with_rate(rate)
      end

      def model_rate(line_item)
        return nil unless priceable?

        amount = match.prices[line_item.kind]
        return nil unless amount.is_a?(Numeric)

        dimension = Usage::Catalog[line_item.kind]
        Pricing::Rate.new(
          amount: amount.to_d,
          quantity: Pricing::RATE_BASIS_QUANTITIES.fetch(dimension.rate_basis).to_d,
          currency: match.source.currency,
          source: match.source.name,
          source_key: "#{match.key}.#{line_item.kind}",
          source_version: match.source.version
        )
      end

      def dimension_for(line_item)
        Usage::Catalog.all.find do |dimension|
          dimension.kind == line_item.kind &&
            dimension.direction == line_item.direction &&
            dimension.modality == line_item.modality &&
            dimension.cache_state == line_item.cache_state &&
            dimension.unit == line_item.unit
        end
      end

      def kept_service_lines
        return @kept_service_lines if defined?(@kept_service_lines)

        @kept_service_lines = begin
          priced_services = priced_line_items.reject(&:token?).select(&:priced?)
          if priced_services.empty?
            []
          else
            base_currency = base_currency_for(token_cost, priced_services)
            matching, mismatched = priced_services.partition { |line| line.currency.to_s == base_currency.to_s }
            warn_currency_mismatch(mismatched, base_currency) if mismatched.any?
            matching
          end
        end
      end

      def combine_service_lines
        cost = token_cost
        return cost if kept_service_lines.empty?

        service_total = kept_service_lines.sum(BigDecimal("0")) { |line| line.cost_value.round(8) }
        Charges::Cost.new(
          components: cost ? cost.components : {}.freeze,
          total: (cost&.total || BigDecimal("0")) + service_total,
          currency: (cost&.currency || kept_service_lines.first.currency).to_s
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
