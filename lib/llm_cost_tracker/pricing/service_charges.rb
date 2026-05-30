# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"

require_relative "../billing/components"
require_relative "../billing/rate"
require_relative "registry"

module LlmCostTracker
  module Pricing
    module ServiceCharges
      extend self

      EMPTY_RATES = {}.freeze

      def reset!
        @builtin_rates = nil
        @file_rates = nil
      end

      def builtin_rates
        @builtin_rates ||= rates_from_registry(
          Registry.raw_registry, context: Registry::DEFAULT_PRICES_PATH
        ).freeze
      end

      def file_rates(path)
        return EMPTY_RATES unless path

        cached = @file_rates
        existing = cached && cached[path]
        return existing if existing

        rates = load_file_rates(path)
        next_cache = cached ? cached.dup : {}
        next_cache[path] = rates
        @file_rates = next_cache.freeze
        rates
      end

      def rates_from_registry(registry, context:)
        data = registry.fetch("service_charges", EMPTY_RATES)
        raise ArgumentError, "#{context} service_charges must be a hash" unless data.is_a?(Hash)

        currency = (registry.dig("metadata", "currency") || Billing::DEFAULT_CURRENCY).upcase
        data.each_with_object({}) do |(provider, entries), rates|
          section_context = "#{context} service_charges.#{provider}"
          rates[provider] = rates_from_section(entries, currency: currency, context: section_context)
        end
      end

      def charge_rate(provider:, component:, pricing_mode:)
        pricing_mode = Pricing::Mode.normalize(pricing_mode)
        match = charge_rate_match(provider: provider, component: component, pricing_mode: pricing_mode)
        return nil unless match

        rate = match.fetch(:rate)
        Billing::Rate.new(
          amount: rate.fetch(:amount),
          quantity: rate.fetch(:quantity),
          currency: rate.fetch(:currency),
          source: match.fetch(:source),
          source_key: match.fetch(:key),
          source_version: Pricing.source_version_for(match.fetch(:source))
        )
      end

      private

      def load_file_rates(path)
        rates_from_registry(Registry.raw_file_registry(path), context: path).freeze
      rescue ArgumentError, TypeError => e
        raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
      end

      def rates_from_section(entries, currency:, context:)
        raise ArgumentError, "#{context} must be a hash" unless entries.is_a?(Hash)

        entries.each_with_object({}) do |(key, amount), rates|
          key = key.to_s
          component, tier = component_and_tier_for(key, context: context)
          amount = amount_for(key, amount, context: context)

          rate = {
            amount: amount,
            quantity: rate_quantity(component),
            currency: currency,
            source_key: key
          }
          component_rates = rates[component.key] ||= { tiers: {} }
          (tier ? component_rates[:tiers] : component_rates)[tier || :default] = rate
        end
      end

      def component_and_tier_for(key, context:)
        component, prefix = Billing::Components.parse_key(key)
        unless component && component.token_key.nil?
          raise ArgumentError, "service charge price key #{key.inspect} in #{context} uses unknown billing component"
        end

        [component, prefix]
      end

      def amount_for(key, amount, context:)
        value = BigDecimal(amount.to_s)
        if value.infinite? || value.nan?
          raise ArgumentError,
                "service charge price amount for #{key.inspect} in #{context} must be finite"
        end
        if value.negative?
          raise ArgumentError,
                "service charge price amount for #{key.inspect} in #{context} must be non-negative"
        end

        value
      end

      def rate_quantity(component)
        BigDecimal(Billing::RATE_BASIS_QUANTITIES.fetch(component.rate_basis).to_s)
      end

      def charge_rate_match(provider:, component:, pricing_mode:)
        provider_name = provider.to_s.presence
        return nil unless provider_name

        component_key = charge_component_key(component)

        table = ServiceCharges.file_rates(LlmCostTracker.configuration.prices_file)
        provider_table = table.fetch(provider_name, EMPTY_RATES)
        rate = rate_for(provider_table, component_key: component_key, pricing_mode: pricing_mode)
        if rate
          return {
            source: "prices_file",
            key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
            rate: rate
          }
        end

        table = ServiceCharges.builtin_rates
        provider_table = table.fetch(provider_name, EMPTY_RATES)
        rate = rate_for(provider_table, component_key: component_key, pricing_mode: pricing_mode)
        return unless rate

        {
          source: "bundled",
          key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
          rate: rate
        }
      end

      def rate_for(provider_table, component_key:, pricing_mode:)
        component_rates = provider_table.fetch(component_key, EMPTY_RATES)
        tier_rates = component_rates.fetch(:tiers, EMPTY_RATES)
        if pricing_mode
          rate = tier_rates[pricing_mode]
          return rate if rate

          tier_rates.each do |candidate, candidate_rate|
            return candidate_rate if tier_includes?(pricing_mode, candidate)
          end
        end
        component_rates[:default]
      end

      def tier_includes?(tier_name, candidate_name)
        tier_name == candidate_name ||
          tier_name.start_with?("#{candidate_name}_") ||
          tier_name.end_with?("_#{candidate_name}") ||
          tier_name.include?("_#{candidate_name}_")
      end

      def charge_component_key(component)
        billing_component = Billing::Components::BY_KEY[component]
        return billing_component.key if billing_component && billing_component.token_key.nil?

        raise Error, "Unknown billing component: #{component.inspect}"
      end
    end
  end
end
