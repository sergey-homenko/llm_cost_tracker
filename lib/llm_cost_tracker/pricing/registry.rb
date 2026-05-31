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
      Match = Data.define(:source, :key, :prices, :matched_by, :currency)
      CACHE_MISS = Object.new.freeze
      NO_MATCH = Object.new.freeze
      LOOKUP_CACHE_LIMIT = 2_048
      class << self
        def reset!
          @builtin_prices = nil
          @metadata = nil
          @raw_registry = nil
          @raw_file_registries = nil
          @file_prices = nil
          @builtin_rates = nil
          @file_rates = nil
          @price_tables = nil
          @lookup_cache = nil
          @sorted_price_keys_cache = nil
          @prices_file_mtime_iso = nil
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

          meta = raw_file_registry(path).fetch("metadata", {})
          return meta if meta.is_a?(Hash)

          raise Error, "Unable to load prices_file #{path.inspect}: prices_file metadata must be a hash"
        end

        def file_prices(path)
          return EMPTY unless path

          prices, @file_prices = memoize_in(@file_prices, path) { load_file_prices(path) }
          prices
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
          registry, @raw_file_registries = memoize_in(@raw_file_registries, path) { load_raw_file_registry(path) }
          registry
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

          rates, @file_rates = memoize_in(@file_rates, path) { load_file_rates(path) }
          rates
        end

        def rates_from_registry(registry, context:)
          data = registry.fetch("service_charges", EMPTY)
          raise ArgumentError, "#{context} service_charges must be a hash" unless data.is_a?(Hash)

          currency = upcased_currency(registry.dig("metadata", "currency"))
          data.each_with_object({}) do |(provider, entries), rates|
            section_context = "#{context} service_charges.#{provider}"
            rates[provider] = rates_from_section(entries, currency: currency, context: section_context)
          end
        end

        def lookup(provider:, model:)
          provider_name = provider.to_s.presence
          model_name = model.to_s
          return nil if model_name.empty?

          cache_key = [provider_name, model_name]
          cached = cached_lookup(cache_key)
          return cached unless cached.equal?(CACHE_MISS)

          match = lookup_match(provider_name: provider_name, model_name: model_name)
          cache_lookup(cache_key, match)
          match
        end

        def prices_file_mtime_iso
          path = LlmCostTracker.configuration.prices_file
          return nil unless path && File.exist?(path)

          @prices_file_mtime_iso ||= File.mtime(path).utc.iso8601
        end

        private

        def memoize_in(cache, key, identity: false)
          existing = cache && cache[key]
          return [existing, cache] if existing

          value = yield
          next_cache = cache&.dup || (identity ? {}.compare_by_identity : {})
          next_cache[key] = value
          [value, next_cache.freeze]
        end

        def loading(path)
          yield
        rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def load_raw_file_registry(path)
          loading(path) { (YAML.safe_load_file(path, aliases: false) || {}).freeze }
        end

        def load_file_prices(path)
          loading(path) do
            doc = raw_file_registry(path)
            normalize_price_entries(doc.fetch("models", doc), context: path).freeze
          end
        end

        def normalize_price_entry(price)
          price.each_with_object({}) do |(key, value), normalized|
            key = registry_key_for(key)
            if key == CONTEXT_THRESHOLD_KEY
              normalized[key] = Integer(value)
            elsif key
              normalized[key] = non_negative_decimal(value, label: "price for #{key.inspect}")
            end
          end
        end

        def non_negative_decimal(value, label:)
          decimal = BigDecimal(value.to_s)
          raise ArgumentError, "#{label} must be finite (got #{value})" unless decimal.finite?
          raise ArgumentError, "#{label} must be non-negative (got #{value})" if decimal.negative?

          decimal
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
          loading(path) { rates_from_registry(raw_file_registry(path), context: path).freeze }
        end

        def rates_from_section(entries, currency:, context:)
          raise ArgumentError, "#{context} must be a hash" unless entries.is_a?(Hash)

          entries.each_with_object({}) do |(key, amount), rates|
            key = key.to_s
            component, tier = component_and_tier_for(key, context: context)
            amount = non_negative_decimal(amount, label: "service charge price amount for #{key.inspect} in #{context}")

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

        def rate_quantity(component)
          BigDecimal(Billing::RATE_BASIS_QUANTITIES.fetch(component.rate_basis).to_s)
        end

        def charge_rate_match(provider:, component:, pricing_mode:)
          provider_name = provider.to_s.presence
          return nil unless provider_name

          component_key = charge_component_key(component)
          sources = [
            ["prices_file", file_rates(LlmCostTracker.configuration.prices_file)],
            ["bundled", builtin_rates]
          ]

          first_match(sources) do |table, source|
            rate = rate_for(table.fetch(provider_name, EMPTY), component_key: component_key, pricing_mode: pricing_mode)
            next unless rate

            {
              source: source,
              key: "service_charges.#{provider_name}.#{rate.fetch(:source_key)}",
              rate: rate
            }
          end
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

        def lookup_match(provider_name:, model_name:)
          provider_model = provider_name ? "#{provider_name}/#{model_name}" : model_name
          normalized = normalize_model_name(model_name)

          first_match(price_tables) do |table, source|
            match_in_table(table, source, provider_model, model_name, normalized)
          end
        end

        def price_tables
          @price_tables ||= begin
            config = LlmCostTracker.configuration
            [
              ["pricing_overrides", config.pricing_overrides],
              ["prices_file", file_prices(config.prices_file)],
              ["bundled", builtin_prices]
            ].freeze
          end
        end

        def first_match(sources)
          sources.each do |source, table|
            result = yield(table, source)
            return result if result
          end
          nil
        end

        def cached_lookup(cache_key)
          cached = @lookup_cache
          return CACHE_MISS unless cached&.key?(cache_key)

          match = cached.fetch(cache_key)
          match.equal?(NO_MATCH) ? nil : match
        end

        def cache_lookup(cache_key, match)
          values = (@lookup_cache || {}).dup
          values.shift while values.size >= LOOKUP_CACHE_LIMIT
          values[cache_key] = match || NO_MATCH
          @lookup_cache = values.freeze
        end

        def match_in_table(table, source, provider_model, model_name, normalized)
          return nil if table.empty?

          [[provider_model, :provider_model], [model_name, :model], [normalized, :normalized_model]].each do |key, by|
            return build_match(table, source, key, by) if table.key?(key)
          end

          scan = native_keys(table)
          if (key = unique_in(scan) { |native| normalize_model_name(native) == normalized })
            return build_match(table, source, key, :unique_providerless_model)
          end

          dated = scan.find do |native|
            snapshot_variant?(provider_model, native) || snapshot_variant?(normalized, native)
          end
          return build_match(table, source, dated, :dated_snapshot) if dated

          unique_dated = unique_in(scan) { |native| snapshot_variant?(normalized, normalize_model_name(native)) }
          return build_match(table, source, unique_dated, :unique_providerless_dated_snapshot) if unique_dated

          nil
        end

        def unique_in(keys, &)
          matches = keys.select(&)
          matches.first if matches.one?
        end

        def normalize_model_name(model)
          model.to_s.split("/").last
        end

        def native_keys(table)
          sorted_price_keys(table).reject { |key| key.count("/") > 1 }
        end

        def build_match(table, source, key, matched_by)
          Match.new(
            source: source,
            key: key,
            prices: table[key],
            matched_by: matched_by,
            currency: source_currency(source)
          )
        end

        def upcased_currency(value)
          (value || Billing::DEFAULT_CURRENCY).upcase
        end

        def source_currency(source)
          raw = case source
                when "bundled" then metadata["currency"]
                when "prices_file"
                  file_metadata(LlmCostTracker.configuration.prices_file)["currency"]
                end
          upcased_currency(raw)
        end

        def snapshot_variant?(model, key)
          suffix = model.delete_prefix("#{key}-")
          return false if suffix == model

          suffix.match?(/\A(?:\d{4}-\d{2}-\d{2}|\d{8}|(?:preview|exp)-\d{2}-\d{2})\z/)
        end

        def sorted_price_keys(table)
          keys, @sorted_price_keys_cache =
            memoize_in(@sorted_price_keys_cache, table, identity: true) { table.keys.sort_by { |key| -key.length } }
          keys
        end
      end
    end
  end
end
