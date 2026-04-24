# frozen_string_literal: true

require "json"
require "monitor"
require "yaml"

require_relative "logging"

module LlmCostTracker
  module PriceRegistry
    DEFAULT_PRICES_PATH = File.expand_path("prices.json", __dir__)
    EMPTY_PRICES = {}.freeze
    PRICE_KEYS = %w[input output cache_read_input cache_write_input].freeze
    METADATA_KEYS = %w[_source _source_version _fetched_at _updated _notes _validator_override].freeze
    MUTEX = Monitor.new

    class << self
      def builtin_prices
        @builtin_prices ||= MUTEX.synchronize do
          @builtin_prices || normalize_price_table(raw_registry.fetch("models", {})).freeze
        end
      end

      def metadata
        @metadata ||= MUTEX.synchronize { @metadata || raw_registry.fetch("metadata", {}).freeze }
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

          value = normalize_file_prices(price_file_models(load_price_file(path)), path: path).freeze
          @file_prices_cache = { key: cache_key, value: value }.freeze
          value
        end
      rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, ArgumentError, TypeError => e
        raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
      end

      private

      def raw_registry
        @raw_registry ||= MUTEX.synchronize do
          @raw_registry || JSON.parse(File.read(DEFAULT_PRICES_PATH)).freeze
        end
      end

      def normalize_price_entry(price)
        price.each_with_object({}) do |(key, value), normalized|
          key = key.to_s
          normalized[key.to_sym] = Float(value) if price_key?(key)
        end
      end

      def normalize_file_prices(table, path:)
        normalize_price_entries(table, context: path)
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
