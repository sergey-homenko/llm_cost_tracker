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
      class << self
        def reset!
          @builtin_prices = nil
          @metadata = nil
          @raw_registry = nil
          @raw_file_registries = nil
          @file_prices = nil
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
          return EMPTY_PRICES unless path

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
