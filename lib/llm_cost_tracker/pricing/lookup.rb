# frozen_string_literal: true

require "monitor"

module LlmCostTracker
  module Pricing
    module Lookup
      Match = Data.define(:source, :key, :prices, :matched_by)
      MUTEX = Monitor.new
      CACHE_MISS = Object.new.freeze
      NO_MATCH = Object.new.freeze
      MAX_LOOKUP_CACHE_ENTRIES = 512

      class << self
        def call(provider:, model:)
          provider_name = provider.to_s
          model_name = model.to_s
          generation = LlmCostTracker.configuration_generation
          cache_key = [generation, provider_name, model_name]
          cached = cached_lookup(cache_key)
          return cached unless cached.equal?(CACHE_MISS)

          provider_model = provider_name.empty? ? model_name : "#{provider_name}/#{model_name}"
          normalized_model = normalize_model_name(model_name)
          current = current_price_tables(generation)

          match =
            explain_table(current.fetch(:pricing_overrides), :pricing_overrides, provider_model, model_name,
                          normalized_model) ||
            explain_table(current.fetch(:file_prices), :prices_file, provider_model, model_name, normalized_model) ||
            explain_table(Pricing::PRICES, :bundled, provider_model, model_name, normalized_model)
          cache_lookup(cache_key, match)
          match
        end

        private

        def current_price_tables(generation)
          cached = @prices_cache
          return cached[:value] if cached && cached[:generation] == generation

          MUTEX.synchronize do
            cached = @prices_cache
            return cached[:value] if cached && cached[:generation] == generation

            config = LlmCostTracker.configuration
            file_prices = PriceRegistry.file_prices(config.prices_file)
            overrides = PriceRegistry.normalize_price_table(config.pricing_overrides)
            value = { pricing_overrides: overrides, file_prices: file_prices }.freeze
            @prices_cache = { generation: generation, value: value }.freeze
            value
          end
        end

        def cached_lookup(cache_key)
          cached = @lookup_cache
          return CACHE_MISS unless cached && cached[:generation] == cache_key.first
          return CACHE_MISS unless cached[:values].key?(cache_key)

          match = cached[:values].fetch(cache_key)
          match.equal?(NO_MATCH) ? nil : match
        end

        def cache_lookup(cache_key, match)
          MUTEX.synchronize do
            cached = @lookup_cache
            values = if cached && cached[:generation] == cache_key.first
                       cached[:values].dup
                     else
                       {}
                     end
            values.clear if values.size >= MAX_LOOKUP_CACHE_ENTRIES
            values[cache_key] = match || NO_MATCH
            @lookup_cache = { generation: cache_key.first, values: values.freeze }.freeze
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
