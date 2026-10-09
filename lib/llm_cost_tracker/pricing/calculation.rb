# frozen_string_literal: true

require "bigdecimal/util"

require_relative "../usage/catalog"
require_relative "../charges/line_item"
require_relative "rate"
require_relative "calculation/iterations"
require_relative "calculation/quantities"
require_relative "calculation/snapshot"
require_relative "calculation/totals"

module LlmCostTracker
  module Pricing
    class Calculation
      RATE_DENOMINATOR_TOKENS = Pricing::RATE_BASIS_QUANTITIES.fetch("per_million_tokens")
      CACHE_INPUT_KEYS = %w[cache_read_input cache_write_input].freeze
      private_constant :RATE_DENOMINATOR_TOKENS, :CACHE_INPUT_KEYS

      def self.for(provider:, model:, tokens:, pricing_mode:, line_items: [], usage_source: nil, at: Time.now)
        new(provider: provider,
            model: model,
            token_usage: Usage::TokenUsage.build_from_tokens(tokens),
            line_items: line_items,
            mode: Mode.normalize(pricing_mode),
            usage_source: usage_source,
            at: at)
      end

      def initialize(provider:, model:, token_usage:, line_items:, mode:, usage_source: nil, at: Time.now)
        @provider = provider
        @model = model
        @token_usage = token_usage
        @line_items = line_items
        @requested_mode = mode
        @usage_source = usage_source
        @at = at
      end

      def mode
        return @mode if defined?(@mode)

        tokens = Mode.tokenize(@requested_mode) - ["off_peak"]
        tokens << "off_peak" if off_peak?
        @mode = Mode.compose(tokens)
      end

      def match
        return @match if defined?(@match)

        @match = Matcher.lookup(provider: @provider, model: @model, at: @at)
      end

      def effective
        return @effective if defined?(@effective)

        @effective = match && EffectivePrices.call(
          usage: @token_usage,
          quantities: quantities,
          prices: match.prices,
          pricing_mode: mode,
          cache_at_input_rate: cache_keys_at_input_rate
        )
      end

      def token_cost
        return @token_cost if defined?(@token_cost)

        known = priceable? && @usage_source != Usage::Source::UNKNOWN && !only_unpriced_lines? && !unsplit_total?
        @token_cost = known ? Totals.token_cost(priced_token_line_items, match.source.currency) : nil
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
            Snapshot.for_match(match, counted_service_lines, priced_token_line_items)
          elsif counted_service_lines.any?
            Snapshot.for_service_charges(counted_service_lines, cost.currency)
          end
      end

      def cost
        return @cost if defined?(@cost)

        @cost = Totals.with_service_lines(token_cost, counted_service_lines)
      end

      def cost_status
        @cost_status ||= begin
          status = billed_status || priced_status
          @iterations&.partial? && status != Charges::CostStatus::UNKNOWN ? Charges::CostStatus::PARTIAL : status
        end
      end

      private

      def off_peak?
        windows = match&.prices&.[](Registry::OFF_PEAK_WINDOWS_KEY)
        windows && OffPeak.cover?(windows, @at)
      end

      def cache_keys_at_input_rate
        return [] if match.source.name == "pricing_overrides" || !match.key.start_with?("openai/")

        listed = Registry.builtin_prices[match.key] || (match.prices unless manual_file_entry?)
        listed ? CACHE_INPUT_KEYS - listed.keys : []
      end

      def manual_file_entry?
        entry = Registry.raw_file_registry(LlmCostTracker.configuration.pricing.file).dig("models", match.key)
        entry.is_a?(Hash) && entry["_source"].to_s == "manual"
      end

      def quantities
        @quantities ||= Quantities.new(@token_usage, @line_items, match&.prices || {}).to_h
      end

      def unpriced_line_items
        Charges::LineItem.from_quantities(quantities) + @line_items.reject(&:token?)
      end

      def priceable?
        !match.nil? && billed_line.nil? && !all_billable_unpriced?
      end

      def billed_line
        @line_items.find { |line_item| line_item.kind == "billed_request" }
      end

      def unsplit_total?
        @token_usage.total_tokens.to_i.positive? && @token_usage.priced_quantities.values.none?(&:positive?) &&
          match.prices.values_at("input", "output").any? { |rate| rate.to_f.positive? }
      end

      def all_billable_unpriced?
        billable = quantities.select { |_key, quantity| quantity.positive? }.keys
        billable.any? && billable.none? { |key| effective[key] }
      end

      def only_unpriced_lines?
        billable = priced_line_items.select(&:billable?)
        billable.any? && billable.none?(&:priced?)
      end

      def price_token(line_item)
        price = priceable? && effective[line_item.dimension.key]
        return line_item unless price

        line_item.with_rate(match.rate(price.amount.to_d, RATE_DENOMINATOR_TOKENS.to_d, price.key))
      end

      def price_service(line_item)
        return iterations.price(line_item) if line_item.kind == "model_iteration"
        return line_item if line_item.priced? || !line_item.billable? || billed_line

        rate = model_rate(line_item) ||
               ServiceRates.charge_rate(provider: @provider, dimension: line_item.kind, pricing_mode: mode)
        return line_item unless rate

        billed_minimum(line_item).with_rate(rate)
      end

      def model_rate(line_item)
        return unless priceable?

        key = model_price_key(line_item.kind)
        return unless key

        quantity = Pricing::RATE_BASIS_QUANTITIES.fetch(Usage::Catalog[line_item.kind].rate_basis)
        match.rate(match.prices[key].to_d, quantity.to_d, "#{match.key}.#{key}")
      end

      def model_price_key(kind)
        modes = mode ? Mode.permutations_for(mode) : []
        [*modes.map { |permutation| PriceKey.build(kind, mode: permutation) }, kind]
          .find { |key| match.prices[key].is_a?(Numeric) }
      end

      def billed_minimum(line_item)
        seconds = match&.prices&.[](Registry::MINIMUM_BILLED_SECONDS_KEY) if line_item.kind == "transcription_minute"
        seconds ? line_item.with(quantity: [line_item.quantity, BigDecimal(seconds) / 60].max) : line_item
      end

      def iterations
        @iterations ||= Iterations.new(provider: @provider, requested_mode: @requested_mode, at: @at)
      end

      def priced_token_line_items
        @priced_token_line_items ||= priced_line_items.select(&:token?)
      end

      def priced_service_line_items
        @priced_service_line_items ||= priced_line_items.reject(&:token?)
      end

      def counted_service_lines
        @counted_service_lines ||= Totals.in_call_currency(priced_service_line_items.select(&:priced?), token_cost)
      end

      def billed_status
        return unless billed_line

        unpriced_attempt = priced_line_items.any? { |item| item.kind == "model_iteration" && item.unpriced? }
        return Charges::CostStatus::PARTIAL if unpriced_attempt

        billed_line.priced? && cost.total.positive? ? Charges::CostStatus::COMPLETE : billed_line.cost_status
      end

      def priced_status
        Charges::CostStatus.call(
          token_usage: @token_usage,
          usage_source: @usage_source,
          token_cost: token_cost,
          token_pricing_partial: !token_cost.nil? && priced_token_line_items.any?(&:unpriced?),
          service_line_items: priced_service_line_items,
          total_cost: cost&.total
        )
      end
    end
  end
end
