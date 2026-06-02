# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "../usage/catalog"
require_relative "registry"
require_relative "rate"
require_relative "mode"

module LlmCostTracker
  module Pricing
    module ServiceRates
      class << self
        def charge_rate(provider:, dimension:, pricing_mode:)
          pricing_mode = Mode.normalize(pricing_mode)
          match = charge_rate_match(provider: provider, dimension: dimension, pricing_mode: pricing_mode)
          return nil unless match

          rate = match.fetch(:rate)
          source = match.fetch(:source)
          Pricing::Rate.new(
            amount: rate.fetch(:amount),
            quantity: rate.fetch(:quantity),
            currency: rate.fetch(:currency),
            source: source.name,
            source_key: match.fetch(:key),
            source_version: source.version
          )
        end

        private

        def charge_rate_match(provider:, dimension:, pricing_mode:)
          provider_name = provider.to_s.presence
          return nil unless provider_name

          dimension_key = charge_dimension_key(dimension)
          Registry.sources.each do |source|
            provider_rates = source.rates.fetch(provider_name, {})
            rate = rate_for(provider_rates, dimension_key: dimension_key, pricing_mode: pricing_mode)
            next unless rate

            return {
              source: source,
              key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
              rate: rate
            }
          end
          nil
        end

        def rate_for(provider_table, dimension_key:, pricing_mode:)
          dimension_rates = provider_table.fetch(dimension_key, {})
          tier_rates = dimension_rates.fetch(:tiers, {})
          if pricing_mode
            rate = tier_rates[pricing_mode]
            return rate if rate

            tier_rates.each do |candidate, candidate_rate|
              return candidate_rate if tier_includes?(pricing_mode, candidate)
            end
          end
          dimension_rates[:default]
        end

        def tier_includes?(tier_name, candidate_name)
          tier_name == candidate_name ||
            tier_name.start_with?("#{candidate_name}_") ||
            tier_name.end_with?("_#{candidate_name}") ||
            tier_name.include?("_#{candidate_name}_")
        end

        def charge_dimension_key(dimension)
          billing_dimension = Usage::Catalog[dimension]
          return billing_dimension.key if billing_dimension && billing_dimension.token_key.nil?

          raise Error, "Unknown billing dimension: #{dimension.inspect}"
        end
      end
    end
  end
end
