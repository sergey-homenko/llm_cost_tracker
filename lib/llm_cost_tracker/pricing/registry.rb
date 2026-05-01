# frozen_string_literal: true

require "json"
require "yaml"

require_relative "../billing/components"
require_relative "../logging"

module LlmCostTracker
  module Pricing
    module Registry
      DEFAULT_PRICES_PATH = File.expand_path("../prices.json", __dir__)
      EMPTY_PRICES = {}.freeze
      PRICE_KEYS = Billing::Components::TOKEN_PRICED.map { |component| component.key.to_s }.freeze
      METADATA_KEYS = %w[
        _source _source_version _fetched_at _updated _notes _validator_override
        _context_price_threshold_tokens
      ].freeze
      MAX_FILE_BYTES = 2_097_152
      MUTEX = Mutex.new

      class << self
        def builtin_prices
          cached = @builtin_prices
          return cached if cached

          value = normalize_price_table(raw_registry.fetch("models", {})).freeze
          MUTEX.synchronize { @builtin_prices ||= value }
        end

        def metadata
          cached = @metadata
          return cached if cached

          value = raw_registry.fetch("metadata", {}).freeze
          MUTEX.synchronize { @metadata ||= value }
        end

        def file_metadata(path)
          return {} unless path

          registry = load_price_file(path.to_s)
          raise ArgumentError, "prices_file must be a hash" unless registry.is_a?(Hash)

          metadata = registry.fetch("metadata", {})
          raise ArgumentError, "prices_file metadata must be a hash" unless metadata.is_a?(Hash)

          metadata
        rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        def normalize_price_table(table)
          normalize_price_entries(table, context: "price table")
        end

        def file_prices(path)
          return EMPTY_PRICES unless path

          path = path.to_s
          cache_key = [path, File.mtime(path).to_f]
          cached = @file_prices_cache
          return cached[:value] if cached && cached[:key] == cache_key

          MUTEX.synchronize do
            cached = @file_prices_cache
            return cached[:value] if cached && cached[:key] == cache_key

            value = normalize_price_entries(price_file_models(load_price_file(path)), context: path).freeze
            @file_prices_cache = { key: cache_key, value: value }.freeze
            value
          end
        rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
        end

        private

        def raw_registry
          cached = @raw_registry
          return cached if cached

          MUTEX.synchronize { @raw_registry ||= JSON.parse(File.read(DEFAULT_PRICES_PATH)).freeze }
        end

        def normalize_price_entry(price)
          price.each_with_object({}) do |(key, value), normalized|
            key = key.to_s
            if price_key?(key)
              normalized[key.to_sym] = Float(value)
            elsif key == "_context_price_threshold_tokens"
              normalized[key.to_sym] = Integer(value)
            end
          end
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
          unknown_keys = price.keys.map(&:to_s).reject do |key|
            price_key?(key) || METADATA_KEYS.include?(key)
          end
          return if unknown_keys.empty?

          Logging.warn(
            "Unknown price keys #{unknown_keys.inspect} for #{model.inspect} in #{path}; " \
            "ignored. Known keys: #{(PRICE_KEYS + METADATA_KEYS).inspect}; mode-specific keys use mode_input"
          )
        end

        def price_key?(key)
          return true if PRICE_KEYS.include?(key)

          PRICE_KEYS.any? do |base_key|
            key.end_with?("_#{base_key}") && key.delete_suffix("_#{base_key}") != ""
          end
        end

        def load_price_file(path)
          raise ArgumentError, "prices_file exceeds #{MAX_FILE_BYTES} bytes" if File.size(path) > MAX_FILE_BYTES

          contents = File.read(path)
          return YAML.safe_load(contents, aliases: false) || {} if yaml_file?(path)

          JSON.parse(contents)
        end

        def yaml_file?(path)
          %w[.yaml .yml].include?(File.extname(path).downcase)
        end

        def price_file_models(registry)
          raise ArgumentError, "prices_file must be a hash" unless registry.is_a?(Hash)

          registry.fetch("models", registry)
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
