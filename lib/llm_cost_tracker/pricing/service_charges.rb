# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "yaml"

require_relative "../billing/components"
require_relative "registry"

module LlmCostTracker
  module Pricing
    module ServiceCharges
      DEFAULT_CURRENCY = "USD"
      EMPTY_RATES = {}.freeze

      class << self
        def builtin_rates
          cached = @builtin_rates
          return cached if cached

          registry = YAML.safe_load_file(Registry::DEFAULT_PRICES_PATH, aliases: false) || {}
          @builtin_rates = rates_from_registry(registry).freeze
        end

        def file_rates(path)
          return EMPTY_RATES unless path

          cache_key = [path, File.mtime(path)]
          cached = @file_rates_cache
          return cached[:value] if cached && cached[:key] == cache_key

          registry = YAML.safe_load_file(path, aliases: false) || {}
          value = rates_from_registry(registry, context: path).freeze
          @file_rates_cache = { key: cache_key, value: value }.freeze
          value
        rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def rates_from_registry(registry, context: "price registry")
          data = registry.fetch("service_charges", EMPTY_RATES)
          raise ArgumentError, "#{context} service_charges must be a hash" unless data.is_a?(Hash)

          data.each_with_object({}) do |(provider, entries), rates|
            section_context = "#{context} service_charges.#{provider}"
            rates[provider] = rates_from_section(entries, context: section_context)
          end
        end

        private

        def rates_from_section(entries, context:)
          raise ArgumentError, "#{context} must be a hash" unless entries.is_a?(Hash)

          entries.each_with_object({}) do |(key, amount), rates|
            key = key.name if key.is_a?(Symbol)
            component, tier = component_and_tier_for(key, context: context)
            amount = amount_for(key, amount, context: context)

            rate = {
              amount: amount,
              quantity: rate_quantity(component),
              currency: DEFAULT_CURRENCY,
              source_key: key
            }
            component_rates = rates[component.key] ||= { tiers: {} }
            if tier
              component_rates[:tiers][tier] = rate
            else
              component_rates[:default] = rate
            end
          end
        end

        def component_and_tier_for(key, context:)
          Billing::Components::REGISTRY.each do |component|
            next if component.token_key

            return [component, nil] if key == component.key.name

            suffix = "_#{component.key.name}"
            next unless key.end_with?(suffix)

            tier = key.delete_suffix(suffix)
            return [component, :"#{tier}"] unless tier.empty?
          end

          raise ArgumentError, "service charge price key #{key.inspect} in #{context} uses unknown billing component"
        end

        def amount_for(key, amount, context:)
          value = BigDecimal(amount.to_s)
          if value.negative?
            raise ArgumentError, "service charge price amount for #{key.inspect} in #{context} must be non-negative"
          end

          value
        end

        def rate_quantity(component)
          component.unit == :request ? BigDecimal("1000") : BigDecimal("1")
        end
      end

      def charge_rate(provider:, component:, tier:)
        match = charge_rate_match(provider: provider, component: component, tier: tier)
        return nil unless match

        rate = match.fetch(:rate)
        {
          amount: rate.fetch(:amount),
          quantity: rate.fetch(:quantity),
          currency: rate.fetch(:currency),
          source: match.fetch(:source),
          source_key: match.fetch(:key),
          source_version: source_version_for(match.fetch(:source))
        }
      end

      private

      def charge_rate_match(provider:, component:, tier:)
        provider_name = provider.is_a?(Symbol) ? provider.name : provider.presence
        return nil unless provider_name

        component_key = charge_component_key(component)
        tier_name = normalize_mode(tier)

        table = ServiceCharges.file_rates(LlmCostTracker.configuration.prices_file)
        provider_table = table.fetch(provider_name, EMPTY_RATES)
        rate = rate_for(provider_table, component_key: component_key, tier_name: tier_name)
        if rate
          return {
            source: :prices_file,
            key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
            rate: rate
          }
        end

        table = ServiceCharges.builtin_rates
        provider_table = table.fetch(provider_name, EMPTY_RATES)
        rate = rate_for(provider_table, component_key: component_key, tier_name: tier_name)
        if rate
          return {
            source: :bundled,
            key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
            rate: rate
          }
        end

        nil
      end

      def rate_for(provider_table, component_key:, tier_name:)
        component_rates = provider_table.fetch(component_key, EMPTY_RATES)
        tier_rate = component_rates.fetch(:tiers, EMPTY_RATES)[tier_name] if tier_name
        tier_rate || component_rates[:default]
      end

      def charge_component_key(component)
        billing_component = Billing::Components::BY_KEY[component]
        return billing_component.key if billing_component && billing_component.token_key.nil?

        raise Error, "Unknown billing component: #{component.inspect}"
      end
    end
  end
end
