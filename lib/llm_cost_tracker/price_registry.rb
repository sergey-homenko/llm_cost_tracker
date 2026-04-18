# frozen_string_literal: true

require "json"
require "yaml"

require_relative "logging"

module LlmCostTracker
  module PriceRegistry
    DEFAULT_PRICES_PATH = File.expand_path("prices.json", __dir__)
    EMPTY_PRICES = {}.freeze
    PRICE_KEYS = %w[input cached_input output cache_read_input cache_creation_input].freeze
    METADATA_KEYS = %w[_source _updated _notes].freeze
    FILE_PRICES_MUTEX = Mutex.new
    NORMALIZE_PRICE_ENTRY = lambda do |price|
      (price || {}).each_with_object({}) do |(key, value), normalized|
        key = key.to_s
        normalized[key.to_sym] = Float(value) if PRICE_KEYS.include?(key)
      end
    end
    NORMALIZE_PRICE_TABLE = lambda do |table|
      (table || {}).each_with_object({}) do |(model, price), normalized|
        normalized[model.to_s] = NORMALIZE_PRICE_ENTRY.call(price)
      end
    end
    RAW_REGISTRY = JSON.parse(File.read(DEFAULT_PRICES_PATH)).freeze
    PRICE_METADATA = RAW_REGISTRY.fetch("metadata", {}).freeze
    BUILTIN_PRICES = NORMALIZE_PRICE_TABLE.call(RAW_REGISTRY.fetch("models", {})).freeze

    private_constant :FILE_PRICES_MUTEX

    class << self
      def builtin_prices
        BUILTIN_PRICES
      end

      def metadata
        PRICE_METADATA
      end

      def normalize_price_table(table)
        NORMALIZE_PRICE_TABLE.call(table)
      end

      def file_prices(path)
        return EMPTY_PRICES unless path

        path = path.to_s
        FILE_PRICES_MUTEX.synchronize do
          cache_key = [path, File.mtime(path).to_f]
          return @file_prices if @file_prices_cache_key == cache_key

          @file_prices_cache_key = cache_key
          @file_prices = normalize_file_prices(price_file_models(load_price_file(path)), path: path).freeze
        end
      rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, ArgumentError, TypeError, NoMethodError => e
        raise Error, "Unable to load prices_file #{path.inspect}: #{e.message}"
      end

      private

      def normalize_file_prices(table, path:)
        (table || {}).each_with_object({}) do |(model, price), normalized|
          warn_unknown_keys(model, price, path)
          normalized[model.to_s] = normalize_price_entry(price)
        end
      end

      def normalize_price_entry(price)
        NORMALIZE_PRICE_ENTRY.call(price)
      end

      def warn_unknown_keys(model, price, path)
        unknown_keys = price.keys.map(&:to_s) - PRICE_KEYS - METADATA_KEYS
        return if unknown_keys.empty?

        Logging.warn(
          "Unknown price keys #{unknown_keys.inspect} for #{model.inspect} in #{path}; " \
          "ignored. Known keys: #{(PRICE_KEYS + METADATA_KEYS).inspect}"
        )
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
        registry.fetch("models", registry)
      end
    end
  end
end
