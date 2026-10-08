# frozen_string_literal: true

require "bigdecimal/util"

require_relative "../../logging"
require_relative "../off_peak"
require_relative "../price_key"
require_relative "../rate"

module LlmCostTracker
  module Pricing
    module Registry
      class Normalizer
        def initialize(context)
          @context = context
        end

        def prices(table)
          table = {} if table.nil?
          raise ArgumentError, "#{@context} must be a hash of models" unless table.is_a?(Hash)

          table.each_with_object({}) { |(model, entry), prices| prices[model.to_s] = price_entry(model, entry) }
        end

        def rates(registry)
          charges = registry.fetch("service_charges", {})
          raise ArgumentError, "#{@context} service_charges must be a hash" unless charges.is_a?(Hash)

          currency = (registry.dig("metadata", "currency") || LlmCostTracker::DEFAULT_CURRENCY).upcase
          charges.to_h do |provider, entries|
            [provider, provider_rates(entries, currency, "#{@context} service_charges.#{provider}")]
          end
        end

        private

        def price_entry(model, entry)
          fields = hash_entry(model, entry).map { |key, value| [key, price_field(model, key, value)] }
          unknown = fields.reject { |key, field| field || METADATA_KEYS.include?(key) }.map(&:first)
          warn_unknown_keys(model, unknown) unless unknown.empty?
          fields.filter_map(&:last).to_h
        end

        def hash_entry(model, entry)
          return {} if entry.nil?
          return entry if entry.is_a?(Hash)

          raise ArgumentError, "price entry for #{model.inspect} in #{@context} must be a hash"
        end

        def price_field(model, key, value)
          name = key.to_s
          case name
          when CONTEXT_THRESHOLD_KEY, MINIMUM_BILLED_SECONDS_KEY then [name, Integer(value)]
          when OFF_PEAK_WINDOWS_KEY then [name, OffPeak.windows(value, label: "#{name} for #{model.inspect}")]
          else
            price_key = PriceKey.price_key_for(name)
            [price_key, amount(value, "price for #{price_key.inspect}")] if price_key
          end
        end

        def warn_unknown_keys(model, keys)
          Logging.warn(
            "Unknown price keys #{keys.inspect} for #{model.inspect} in #{@context}; " \
            "ignored. Known keys: #{(PRICE_KEYS + METADATA_KEYS).inspect}; mode-specific keys use mode_input"
          )
        end

        def provider_rates(entries, currency, context)
          raise ArgumentError, "#{context} must be a hash" unless entries.is_a?(Hash)

          entries.each_with_object({}) do |(key, value), rates|
            dimension, tier = dimension_and_tier(key.to_s, context)
            rate = service_rate(key.to_s, value, dimension, currency, context)
            dimension_rates = rates[dimension.key] ||= { tiers: {} }
            if tier
              dimension_rates[:tiers][tier] = rate
            else
              dimension_rates[:default] = rate
            end
          end
        end

        def dimension_and_tier(key, context)
          dimension, tier = PriceKey.parse_dimension_key(key)
          return [dimension, tier] if dimension && dimension.token_key.nil?

          raise ArgumentError, "service charge price key #{key.inspect} in #{context} uses unknown billing dimension"
        end

        def service_rate(key, value, dimension, currency, context)
          {
            amount: amount(value, "service charge price amount for #{key.inspect} in #{context}"),
            quantity: Pricing::RATE_BASIS_QUANTITIES.fetch(dimension.rate_basis).to_d,
            currency: currency,
            source_key: key
          }
        end

        def amount(value, label)
          decimal = BigDecimal(value.to_s)
          raise ArgumentError, "#{label} must be finite (got #{value})" unless decimal.finite?
          raise ArgumentError, "#{label} must be non-negative (got #{value})" if decimal.negative?

          decimal
        end
      end
    end
  end
end
