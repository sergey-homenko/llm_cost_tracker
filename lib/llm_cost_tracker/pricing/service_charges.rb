# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "time"
require "yaml"

require_relative "../billing/components"
require_relative "registry"

module LlmCostTracker
  module Pricing
    module ServiceCharges
      extend self

      DEFAULT_CURRENCY = "USD"
      EMPTY_RATES = {}.freeze
      MUTEX = Mutex.new

      def reset!
        MUTEX.synchronize do
          @builtin_rates = nil
          @file_rates_cache = nil
        end
      end

      def builtin_rates
        cached = @builtin_rates
        return cached if cached

        MUTEX.synchronize do
          @builtin_rates ||= begin
            registry = YAML.safe_load_file(Registry::DEFAULT_PRICES_PATH, aliases: false) || {}
            rates_from_registry(registry).freeze
          end
        end
      end

      def file_rates(path)
        return EMPTY_RATES unless path

        cache_key = [path, File.mtime(path)]
        cached = @file_rates_cache
        return cached[:value] if cached && cached[:key] == cache_key

        MUTEX.synchronize do
          cached = @file_rates_cache
          return cached[:value] if cached && cached[:key] == cache_key

          registry = YAML.safe_load_file(path, aliases: false) || {}
          value = rates_from_registry(registry, context: path).freeze
          @file_rates_cache = { key: cache_key, value: value }.freeze
          value
        end
      rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
        raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
      end

      def rates_from_registry(registry, context: "price registry")
        data = registry.fetch("service_charges", EMPTY_RATES)
        raise ArgumentError, "#{context} service_charges must be a hash" unless data.is_a?(Hash)

        currency = registry.dig("metadata", "currency") || DEFAULT_CURRENCY
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
        {
          amount: rate.fetch(:amount),
          quantity: rate.fetch(:quantity),
          currency: rate.fetch(:currency),
          source: match.fetch(:source),
          source_key: match.fetch(:key),
          source_version: rate_source_version_for(match.fetch(:source))
        }
      end

      private

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
        BigDecimal(Billing::RATE_BASIS_QUANTITIES.fetch(component.rate_basis, 1).to_s)
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
            source: :prices_file,
            key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
            rate: rate
          }
        end

        table = ServiceCharges.builtin_rates
        provider_table = table.fetch(provider_name, EMPTY_RATES)
        rate = rate_for(provider_table, component_key: component_key, pricing_mode: pricing_mode)
        return unless rate

        {
          source: :bundled,
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

          name = pricing_mode.name
          tier_rates.each do |candidate, candidate_rate|
            return candidate_rate if tier_includes?(name, candidate.name)
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

      def rate_source_version_for(source)
        return LlmCostTracker::VERSION if source == :bundled

        Lookup.prices_file_mtime_iso
      end
    end
  end
end
