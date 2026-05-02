# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Lookup
      Match = Data.define(:source, :key, :prices, :matched_by)
      MUTEX = Mutex.new
      CACHE_MISS = Object.new.freeze
      NO_MATCH = Object.new.freeze

      class << self
        def call(provider:, model:)
          provider_name = provider.to_s.presence
          model_name = model.to_s
          cache_key = [provider_name, model_name]
          cached = cached_lookup(cache_key)
          return cached unless cached.equal?(CACHE_MISS)

          provider_model = provider_name ? "#{provider_name}/#{model_name}" : model_name
          normalized_model = normalize_model_name(model_name)
          current = current_price_tables

          match =
            explain_table(
              table: current.fetch(:pricing_overrides),
              source: :pricing_overrides,
              provider_model: provider_model,
              model_name: model_name,
              normalized_model: normalized_model
            ) ||
            explain_table(
              table: current.fetch(:file_prices),
              source: :prices_file,
              provider_model: provider_model,
              model_name: model_name,
              normalized_model: normalized_model
            ) ||
            explain_table(
              table: Registry.builtin_prices,
              source: :bundled,
              provider_model: provider_model,
              model_name: model_name,
              normalized_model: normalized_model
            )
          cache_lookup(cache_key, match)
          match
        end

        def reset!
          MUTEX.synchronize do
            @prices_cache = nil
            @lookup_cache = nil
            @sorted_price_keys_cache = nil
          end
        end

        private

        def current_price_tables
          cached = @prices_cache
          return cached if cached

          MUTEX.synchronize do
            cached = @prices_cache
            return cached if cached

            config = LlmCostTracker.configuration
            file_prices = Registry.file_prices(config.prices_file)
            overrides = Registry.normalize_price_table(config.pricing_overrides)
            value = { pricing_overrides: overrides, file_prices: file_prices }.freeze
            @prices_cache = value
            value
          end
        end

        def cached_lookup(cache_key)
          cached = @lookup_cache
          return CACHE_MISS unless cached&.key?(cache_key)

          match = cached.fetch(cache_key)
          match.equal?(NO_MATCH) ? nil : match
        end

        def cache_lookup(cache_key, match)
          MUTEX.synchronize do
            values = (@lookup_cache || {}).dup
            values[cache_key] = match || NO_MATCH
            @lookup_cache = values.freeze
          end
        end

        def explain_table(table:, source:, provider_model:, model_name:, normalized_model:)
          return nil if table.empty?

          direct_match(table: table, source: source, key: provider_model, matched_by: :provider_model) ||
            direct_match(table: table, source: source, key: model_name, matched_by: :model) ||
            direct_match(table: table, source: source, key: normalized_model, matched_by: :normalized_model) ||
            unique_providerless_lookup(model: normalized_model, table: table, source: source) ||
            fuzzy_match(model: provider_model, normalized_model: normalized_model, table: table, source: source) ||
            unique_providerless_fuzzy_match(model: normalized_model, table: table, source: source)
        end

        def normalize_model_name(model)
          model.to_s.split("/").last
        end

        def unique_providerless_lookup(model:, table:, source:)
          matches = sorted_price_keys(table).select { |key| normalize_model_name(key) == model }
          return unless matches.one?

          match(table: table, source: source, key: matches.first, matched_by: :unique_providerless_model)
        end

        def fuzzy_match(model:, normalized_model:, table:, source:)
          sorted_price_keys(table).each do |key|
            if snapshot_variant?(model, key) || snapshot_variant?(normalized_model, key)
              return match(table: table, source: source, key: key, matched_by: :dated_snapshot)
            end
          end

          nil
        end

        def unique_providerless_fuzzy_match(model:, table:, source:)
          matches = sorted_price_keys(table).select { |key| snapshot_variant?(model, normalize_model_name(key)) }
          return unless matches.one?

          match(table: table, source: source, key: matches.first, matched_by: :unique_providerless_dated_snapshot)
        end

        def direct_match(table:, source:, key:, matched_by:)
          match(table: table, source: source, key: key, matched_by: matched_by) if table.key?(key)
        end

        def match(table:, source:, key:, matched_by:)
          Match.new(source: source, key: key, prices: table[key], matched_by: matched_by)
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
