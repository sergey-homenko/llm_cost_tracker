# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "yaml"

require_relative "../usage/catalog"
require_relative "../logging"
require_relative "source"
require_relative "registry/normalizer"

module LlmCostTracker
  module Pricing
    module Registry
      DEFAULT_PRICES_PATH = File.expand_path("../prices.json", __dir__)
      CONTEXT_THRESHOLD_KEY = "_context_price_threshold_tokens"
      OFF_PEAK_WINDOWS_KEY = "_off_peak_windows"
      MINIMUM_BILLED_SECONDS_KEY = "_minimum_billed_seconds"
      PRICE_KEYS = Usage::Catalog.all.select(&:token?).map(&:key).freeze
      METADATA_KEYS = ["_source", CONTEXT_THRESHOLD_KEY, OFF_PEAK_WINDOWS_KEY, MINIMUM_BILLED_SECONDS_KEY].freeze

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

        def validate_file!(path)
          file_prices(path)
          file_rates(path)
          file_metadata(path)
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
          Normalizer.new(context).prices(table)
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
          Normalizer.new(context).rates(registry)
        end

        def prices_file_mtime_iso
          path = LlmCostTracker.configuration.pricing.file
          return nil unless path && File.exist?(path)

          @prices_file_mtime_iso ||= File.mtime(path).utc.iso8601
        end

        def sources
          @sources ||= [overrides_source, file_source, bundled_source].freeze
        end

        def sorted_price_keys(table)
          keys, @sorted_price_keys_cache =
            memoize_in(@sorted_price_keys_cache, table, identity: true) { table.keys.sort_by { |key| -key.length } }
          keys
        end

        private

        def overrides_source
          Source.new(
            name: "pricing_overrides",
            prices: LlmCostTracker.configuration.pricing.overrides,
            rates: {},
            currency: upcased_currency(nil),
            version: "configuration"
          )
        end

        def file_source
          path = LlmCostTracker.configuration.pricing.file
          Source.new(
            name: "prices_file",
            prices: file_prices(path),
            rates: file_rates(path),
            currency: upcased_currency(file_metadata(path)["currency"]),
            version: prices_file_mtime_iso
          )
        end

        def bundled_source
          Source.new(
            name: "bundled",
            prices: builtin_prices,
            rates: builtin_rates,
            currency: upcased_currency(metadata["currency"]),
            version: LlmCostTracker::VERSION
          )
        end

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
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}; fix or delete it"
        end

        def load_raw_file_registry(path)
          unless File.exist?(path)
            Logging.warn("pricing.file #{path} does not exist; using bundled prices until prices:refresh creates it")
            return {}.freeze
          end

          loading(path) { (YAML.safe_load_file(path, aliases: false) || {}).freeze }
        end

        def load_file_prices(path)
          loading(path) do
            doc = raw_file_registry(path)
            normalize_price_entries(doc.fetch("models", doc), context: path).freeze
          end
        end

        def load_file_rates(path)
          loading(path) { rates_from_registry(raw_file_registry(path), context: path).freeze }
        end

        def upcased_currency(value)
          (value || LlmCostTracker::DEFAULT_CURRENCY).upcase
        end
      end
    end
  end
end
