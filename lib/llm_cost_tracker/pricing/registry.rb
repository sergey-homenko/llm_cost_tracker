# frozen_string_literal: true

require "yaml"

require_relative "../billing/components"
require_relative "../logging"

module LlmCostTracker
  module Pricing
    module Registry
      DEFAULT_PRICES_PATH = File.expand_path("../prices.json", __dir__)
      EMPTY_PRICES = {}.freeze
      CONTEXT_THRESHOLD_KEY = "_context_price_threshold_tokens"
      PRICE_KEYS = Billing::Components::TOKEN_PRICED.map(&:key).freeze
      METADATA_KEYS = [
        "_source", "_source_version", "_fetched_at", "_updated", "_notes", "_validator_override",
        CONTEXT_THRESHOLD_KEY
      ].freeze
      MUTEX = Mutex.new

      class << self
        def reset!
          MUTEX.synchronize do
            @builtin_prices = nil
            @metadata = nil
            @raw_registry = nil
            @file_prices_cache = nil
          end
        end

        def builtin_prices
          cached = @builtin_prices
          return cached if cached

          MUTEX.synchronize do
            @builtin_prices ||= begin
              registry = @raw_registry ||= load_raw_registry
              normalize_price_table(registry.fetch("models", {})).freeze
            end
          end
        end

        def metadata
          cached = @metadata
          return cached if cached

          MUTEX.synchronize do
            @metadata ||= begin
              registry = @raw_registry ||= load_raw_registry
              registry.fetch("metadata", {}).freeze
            end
          end
        end

        def file_metadata(path)
          return {} unless path

          registry = YAML.safe_load_file(path, aliases: false) || {}

          metadata = registry.fetch("metadata", {})
          raise ArgumentError, "prices_file metadata must be a hash" unless metadata.is_a?(Hash)

          metadata
        rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def normalize_price_table(table)
          normalize_price_entries(table, context: "price table")
        end

        def file_prices(path)
          return EMPTY_PRICES unless path

          cache_key = [path, File.mtime(path)]
          cached = @file_prices_cache
          return cached[:value] if cached && cached[:key] == cache_key

          MUTEX.synchronize do
            cached = @file_prices_cache
            return cached[:value] if cached && cached[:key] == cache_key

            registry = YAML.safe_load_file(path, aliases: false) || {}
            value = normalize_price_entries(registry.fetch("models", registry), context: path).freeze
            @file_prices_cache = { key: cache_key, value: value }.freeze
            value
          end
        rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        private

        def load_raw_registry
          YAML.safe_load_file(DEFAULT_PRICES_PATH, aliases: false).freeze
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

        def normalize_price_entries(table, context:)
          table = {} if table.nil?
          raise ArgumentError, "#{context} must be a hash of models" unless table.is_a?(Hash)

          table.each_with_object({}) do |(model, price), normalized|
            price = validate_price_entry(price, model: model, context: context)
            warn_unknown_keys(model, price, context)
            normalized[model.to_s] = normalize_price_entry(price)
          end
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
          name = key.to_s
          Billing::Components::REGISTRY.each do |candidate|
            return candidate.key if candidate.key == name
            next unless candidate.token_key

            suffix = "_#{candidate.key}"
            next unless name.end_with?(suffix)

            prefix = name.delete_suffix(suffix)
            return "#{prefix}_#{candidate.key}" unless prefix.empty?
          end

          nil
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
      end
    end
  end
end
