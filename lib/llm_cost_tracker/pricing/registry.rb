# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "yaml"

require_relative "../billing/components"
require_relative "../billing/rate"
require_relative "../logging"
require_relative "mode"

module LlmCostTracker
  module Pricing
    module Registry
      DEFAULT_PRICES_PATH = File.expand_path("../prices.json", __dir__)
      EMPTY = {}.freeze
      CONTEXT_THRESHOLD_KEY = "_context_price_threshold_tokens"
      PRICE_KEYS = Billing::Components::TOKEN_PRICED.map(&:key).freeze
      METADATA_KEYS = [
        "_source", "_source_version", "_fetched_at", "_updated", "_notes", "_validator_override",
        CONTEXT_THRESHOLD_KEY
      ].freeze
      class << self
        def reset!
          @builtin_prices = nil
          @metadata = nil
          @raw_registry = nil
          @raw_file_registries = nil
          @file_prices = nil
          @builtin_rates = nil
          @file_rates = nil
        end

        def builtin_prices
          @builtin_prices ||= normalize_price_entries(
            raw_registry.fetch("models", {}), context: "bundled prices"
          ).freeze
        end

        def metadata
          @metadata ||= raw_registry.fetch("metadata", {}).freeze
        end

        def file_metadata(path)
          return {} unless path

          metadata = raw_file_registry(path).fetch("metadata", {})
          raise ArgumentError, "prices_file metadata must be a hash" unless metadata.is_a?(Hash)

          metadata
        rescue ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def file_prices(path)
          return EMPTY unless path

          (@file_prices ||= {})[path] ||= load_file_prices(path)
        end

        def normalize_price_entries(table, context:)
          table = {} if table.nil?
          raise ArgumentError, "#{context} must be a hash of models" unless table.is_a?(Hash)

          table.each_with_object({}) do |(model, price), normalized|
            price = validate_price_entry(price, model: model, context: context)
            warn_unknown_keys(model, price, context)
            normalized[model.to_s] = normalize_price_entry(price)
          end
        end

        def raw_registry
          @raw_registry ||= YAML.safe_load_file(DEFAULT_PRICES_PATH, aliases: false).freeze
        end

        def raw_file_registry(path)
          (@raw_file_registries ||= {})[path] ||= load_raw_file_registry(path)
        end

        def charge_rate(provider:, component:, pricing_mode:)
          pricing_mode = Mode.normalize(pricing_mode)
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

        def builtin_rates
          @builtin_rates ||= rates_from_registry(raw_registry, context: DEFAULT_PRICES_PATH).freeze
        end

        def file_rates(path)
          return EMPTY unless path

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
          data = registry.fetch("service_charges", EMPTY)
          raise ArgumentError, "#{context} service_charges must be a hash" unless data.is_a?(Hash)

          currency = (registry.dig("metadata", "currency") || Billing::DEFAULT_CURRENCY).upcase
          data.each_with_object({}) do |(provider, entries), rates|
            section_context = "#{context} service_charges.#{provider}"
            rates[provider] = rates_from_section(entries, currency: currency, context: section_context)
          end
        end

        private

        def load_raw_file_registry(path)
          (YAML.safe_load_file(path, aliases: false) || {}).freeze
        rescue Errno::ENOENT, Psych::Exception => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def load_file_prices(path)
          doc = raw_file_registry(path)
          normalize_price_entries(doc.fetch("models", doc), context: path).freeze
        rescue ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def normalize_price_entry(price)
          price.each_with_object({}) do |(key, value), normalized|
            key = registry_key_for(key)
            if key == CONTEXT_THRESHOLD_KEY
              normalized[key] = Integer(value)
            elsif key
              normalized[key] = non_negative_float(key, value)
            end
          end
        end

        def non_negative_float(key, value)
          rate = Float(value)
          raise ArgumentError, "price for #{key.inspect} must be finite (got #{rate})" unless rate.finite?
          raise ArgumentError, "price for #{key.inspect} must be non-negative (got #{rate})" if rate.negative?

          rate
        end

        def warn_unknown_keys(model, price, path)
          unknown_keys = price.keys.reject do |key|
            registry_key_for(key) || METADATA_KEYS.include?(key)
          end
          return if unknown_keys.empty?

          Logging.warn(
            "Unknown price keys #{unknown_keys.inspect} for #{model.inspect} in #{path}; " \
            "ignored. Known keys: #{(PRICE_KEYS + METADATA_KEYS).inspect}; mode-specific keys use mode_input"
          )
        end

        def price_key_for(key)
          component, prefix = Billing::Components.parse_key(key)
          return nil unless component
          return component.key if prefix.nil?
          return nil unless component.token_key

          "#{prefix}_#{component.key}"
        end

        def registry_key_for(key)
          return CONTEXT_THRESHOLD_KEY if key.to_s == CONTEXT_THRESHOLD_KEY

          price_key_for(key)
        end

        def validate_price_entry(price, model:, context:)
          return {} if price.nil?
          return price if price.is_a?(Hash)

          raise ArgumentError, "price entry for #{model.inspect} in #{context} must be a hash"
        end

        def load_file_rates(path)
          rates_from_registry(raw_file_registry(path), context: path).freeze
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

          table = file_rates(LlmCostTracker.configuration.prices_file)
          provider_table = table.fetch(provider_name, EMPTY)
          rate = rate_for(provider_table, component_key: component_key, pricing_mode: pricing_mode)
          if rate
            return {
              source: "prices_file",
              key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
              rate: rate
            }
          end

          table = builtin_rates
          provider_table = table.fetch(provider_name, EMPTY)
          rate = rate_for(provider_table, component_key: component_key, pricing_mode: pricing_mode)
          return unless rate

          {
            source: "bundled",
            key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
            rate: rate
          }
        end

        def rate_for(provider_table, component_key:, pricing_mode:)
          component_rates = provider_table.fetch(component_key, EMPTY)
          tier_rates = component_rates.fetch(:tiers, EMPTY)
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
end
