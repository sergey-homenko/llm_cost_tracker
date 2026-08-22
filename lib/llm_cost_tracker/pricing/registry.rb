# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal/util"
require "yaml"

require_relative "../usage/catalog"
require_relative "../pricing/rate"
require_relative "../logging"
require_relative "mode"
require_relative "price_key"
require_relative "source"

module LlmCostTracker
  module Pricing
    module Registry
      DEFAULT_PRICES_PATH = File.expand_path("../prices.json", __dir__)
      CONTEXT_THRESHOLD_KEY = "_context_price_threshold_tokens"
      PRICE_KEYS = Usage::Catalog.token_priced.map(&:key).freeze
      METADATA_KEYS = ["_source", CONTEXT_THRESHOLD_KEY].freeze

      class << self
        def reset!
          @builtin_prices = nil
          @metadata = nil
          @raw_registry = nil
          @raw_file_registries = nil
          @file_prices = nil
          @builtin_rates = nil
          @file_rates = nil
          @sources = nil
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
          return {} unless path

          prices, @file_prices = memoize_in(@file_prices, path) { load_file_prices(path) }
          prices
        end

        def normalize_price_entries(table, context:)
          table = {} if table.nil?
          raise ArgumentError, "#{context} must be a hash of models" unless table.is_a?(Hash)

          table.each_with_object({}) do |(model, price), normalized|
            price = validate_price_entry(price, model: model, context: context)
            normalized[model.to_s] = normalize_price_entry(model, price, context)
          end
        end

        def raw_registry
          @raw_registry ||= YAML.safe_load_file(DEFAULT_PRICES_PATH, aliases: false).freeze
        end

        def raw_file_registry(path)
          registry, @raw_file_registries = memoize_in(@raw_file_registries, path) { load_raw_file_registry(path) }
          registry
        end

        def builtin_rates
          @builtin_rates ||= rates_from_registry(raw_registry, context: DEFAULT_PRICES_PATH).freeze
        end

        def file_rates(path)
          return {} unless path

          rates, @file_rates = memoize_in(@file_rates, path) { load_file_rates(path) }
          rates
        end

        def rates_from_registry(registry, context:)
          data = registry.fetch("service_charges", {})
          raise ArgumentError, "#{context} service_charges must be a hash" unless data.is_a?(Hash)

          currency = upcased_currency(registry.dig("metadata", "currency"))
          data.each_with_object({}) do |(provider, entries), rates|
            section_context = "#{context} service_charges.#{provider}"
            rates[provider] = rates_from_section(entries, currency: currency, context: section_context)
          end
        end

        def prices_file_mtime_iso
          path = LlmCostTracker.configuration.pricing.file
          return nil unless path && File.exist?(path)

          @prices_file_mtime_iso ||= File.mtime(path).utc.iso8601
        end

        def sources
          @sources ||= begin
            config = LlmCostTracker.configuration
            [
              Source.new(
                name: "pricing_overrides",
                prices: config.pricing.overrides,
                rates: {},
                currency: upcased_currency(nil),
                version: "configuration"
              ),
              Source.new(
                name: "prices_file",
                prices: file_prices(config.pricing.file),
                rates: file_rates(config.pricing.file),
                currency: upcased_currency(file_metadata(config.pricing.file)["currency"]),
                version: prices_file_mtime_iso
              ),
              Source.new(
                name: "bundled",
                prices: builtin_prices,
                rates: builtin_rates,
                currency: upcased_currency(metadata["currency"]),
                version: LlmCostTracker::VERSION
              )
            ].freeze
          end
        end

        def sorted_price_keys(table)
          keys, @sorted_price_keys_cache =
            memoize_in(@sorted_price_keys_cache, table, identity: true) { table.keys.sort_by { |key| -key.length } }
          keys
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

        def normalize_price_entry(model, price, context)
          unknown = []
          normalized = price.each_with_object({}) do |(key, value), acc|
            registry_key = registry_key_for(key)
            if registry_key == CONTEXT_THRESHOLD_KEY
              acc[registry_key] = Integer(value)
            elsif registry_key
              acc[registry_key] = non_negative_decimal(value, label: "price for #{registry_key.inspect}")
            elsif !METADATA_KEYS.include?(key)
              unknown << key
            end
          end
          warn_unknown_keys(model, unknown, context) unless unknown.empty?
          normalized
        end

        def non_negative_decimal(value, label:)
          decimal = BigDecimal(value.to_s)
          raise ArgumentError, "#{label} must be finite (got #{value})" unless decimal.finite?
          raise ArgumentError, "#{label} must be non-negative (got #{value})" if decimal.negative?

          decimal
        end

        def warn_unknown_keys(model, unknown_keys, path)
          Logging.warn(
            "Unknown price keys #{unknown_keys.inspect} for #{model.inspect} in #{path}; " \
            "ignored. Known keys: #{(PRICE_KEYS + METADATA_KEYS).inspect}; mode-specific keys use mode_input"
          )
        end

        def registry_key_for(key)
          return CONTEXT_THRESHOLD_KEY if key.to_s == CONTEXT_THRESHOLD_KEY

          PriceKey.price_key_for(key)
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
            dimension, tier = dimension_and_tier_for(key, context: context)
            amount = non_negative_decimal(amount, label: "service charge price amount for #{key.inspect} in #{context}")

            rate = {
              amount: amount,
              quantity: rate_quantity(dimension),
              currency: currency,
              source_key: key
            }
            dimension_rates = rates[dimension.key] ||= { tiers: {} }
            (tier ? dimension_rates[:tiers] : dimension_rates)[tier || :default] = rate
          end
        end

        def dimension_and_tier_for(key, context:)
          dimension, tier = PriceKey.parse_dimension_key(key)
          unless dimension && dimension.token_key.nil?
            raise ArgumentError, "service charge price key #{key.inspect} in #{context} uses unknown billing dimension"
          end

          [dimension, tier]
        end

        def rate_quantity(dimension)
          Pricing::RATE_BASIS_QUANTITIES.fetch(dimension.rate_basis).to_d
        end

        def upcased_currency(value)
          (value || LlmCostTracker::DEFAULT_CURRENCY).upcase
        end
      end
    end
  end
end
