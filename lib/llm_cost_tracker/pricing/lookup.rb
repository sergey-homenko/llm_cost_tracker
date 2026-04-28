# frozen_string_literal: true

require "monitor"

module LlmCostTracker
  module Pricing
    module Lookup
      Match = Data.define(:source, :key, :prices, :matched_by)
      MUTEX = Monitor.new

      class << self
        def call(provider:, model:)
          provider_name = provider.to_s
          model_name = model.to_s
          provider_model = provider_name.empty? ? model_name : "#{provider_name}/#{model_name}"
          normalized_model = normalize_model_name(model_name)
          current = current_price_tables

          explain_table(current.fetch(:pricing_overrides), :pricing_overrides, provider_model, model_name,
                        normalized_model) ||
            explain_table(current.fetch(:file_prices), :prices_file, provider_model, model_name, normalized_model) ||
            explain_table(Pricing::PRICES, :bundled, provider_model, model_name, normalized_model)
        end

        private

        def current_price_tables
          file_prices = PriceRegistry.file_prices(LlmCostTracker.configuration.prices_file)
          overrides = PriceRegistry.normalize_price_table(LlmCostTracker.configuration.pricing_overrides)
          cache_key = [file_prices.object_id, LlmCostTracker.configuration.pricing_overrides.hash]

          cached = @prices_cache
          return cached[:value] if cached && cached[:key] == cache_key

          MUTEX.synchronize do
            cached = @prices_cache
            return cached[:value] if cached && cached[:key] == cache_key

            value = { pricing_overrides: overrides, file_prices: file_prices }.freeze
            @prices_cache = { key: cache_key, value: value }.freeze
            value
          end
        end

        def explain_table(table, source, provider_model, model_name, normalized_model)
          return nil if table.empty?

          direct_match(table, source, provider_model, :provider_model) ||
            direct_match(table, source, model_name, :model) ||
            direct_match(table, source, normalized_model, :normalized_model) ||
            unique_providerless_lookup(normalized_model, table, source) ||
            fuzzy_match(provider_model, normalized_model, table, source) ||
            unique_providerless_fuzzy_match(normalized_model, table, source)
        end

        def normalize_model_name(model)
          model.to_s.split("/").last
        end

        def unique_providerless_lookup(model, table, source)
          matches = sorted_price_keys(table).select { |key| normalize_model_name(key) == model }
          match(table, source, matches.first, :unique_providerless_model) if matches.one?
        end

        def fuzzy_match(model, normalized_model, table, source)
          sorted_price_keys(table).each do |key|
            return match(table, source, key, :dated_snapshot) if snapshot_variant?(model, key) ||
                                                                 snapshot_variant?(normalized_model, key)
          end

          nil
        end

        def unique_providerless_fuzzy_match(model, table, source)
          matches = sorted_price_keys(table).select { |key| snapshot_variant?(model, normalize_model_name(key)) }
          match(table, source, matches.first, :unique_providerless_dated_snapshot) if matches.one?
        end

        def direct_match(table, source, key, matched_by)
          match(table, source, key, matched_by) if table.key?(key)
        end

        def match(table, source, key, matched_by)
          Match.new(source.to_s, key, table[key], matched_by.to_s)
        end

        def snapshot_variant?(model, key)
          suffix = model.delete_prefix("#{key}-")
          return false if suffix == model

          suffix.match?(/\A(?:\d{4}-\d{2}-\d{2}|\d{8})\z/)
        end

        def sorted_price_keys(table)
          cached = @sorted_price_keys_cache
          return cached[:keys] if cached && cached[:table].equal?(table)

          MUTEX.synchronize do
            cached = @sorted_price_keys_cache
            return cached[:keys] if cached && cached[:table].equal?(table)

            keys = table.keys.sort_by { |key| -key.length }
            @sorted_price_keys_cache = { table: table, keys: keys }.freeze
            keys
          end
        end
      end
    end
  end
end
