# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Lookup
      Match = Data.define(:source, :key, :prices, :matched_by, :currency)
      MUTEX = Mutex.new
      CACHE_MISS = Object.new.freeze
      NO_MATCH = Object.new.freeze
      LOOKUP_CACHE_LIMIT = 2_048
      PRICE_FILE_RECHECK_INTERVAL = 1.0
      private_constant :PRICE_FILE_RECHECK_INTERVAL

      class << self
        def call(provider:, model:)
          provider_name = provider.to_s.presence
          model_name = model.to_s
          return nil if model_name.empty?

          invalidate_cache_if_prices_file_changed!

          cache_key = [provider_name, model_name]
          cached = cached_lookup(cache_key)
          return cached unless cached.equal?(CACHE_MISS)

          match = lookup_match(provider_name: provider_name, model_name: model_name)
          cache_lookup(cache_key, match)
          match
        end

        def reset!
          MUTEX.synchronize do
            reset_prices_caches!(signature: nil)
            @prices_file_last_check_at = nil
          end
        end

        def prices_file_mtime_iso
          invalidate_cache_if_prices_file_changed!
          signature = @prices_file_signature
          return nil unless signature

          cached = @prices_file_iso_cache
          return cached[:value] if cached && cached[:mtime] == signature

          MUTEX.synchronize do
            cached = @prices_file_iso_cache
            return cached[:value] if cached && cached[:mtime] == signature

            iso = signature.utc.iso8601
            @prices_file_iso_cache = { mtime: signature, value: iso }.freeze
            iso
          end
        end

        private

        def invalidate_cache_if_prices_file_changed!
          path = LlmCostTracker.configuration.prices_file

          unless path
            return if @prices_file_signature.nil?

            MUTEX.synchronize { reset_prices_caches!(signature: nil) unless @prices_file_signature.nil? }
            return
          end

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          last_check = @prices_file_last_check_at
          return if last_check && (now - last_check) < PRICE_FILE_RECHECK_INTERVAL

          signature = File.exist?(path) ? File.mtime(path) : nil
          MUTEX.synchronize do
            @prices_file_last_check_at = now
            reset_prices_caches!(signature: signature) if @prices_file_signature != signature
          end
        end

        def reset_prices_caches!(signature:)
          @prices_cache = nil
          @lookup_cache = nil
          @sorted_price_keys_cache = nil
          @prices_file_iso_cache = nil
          @prices_file_signature = signature
        end

        def lookup_match(provider_name:, model_name:)
          provider_model = provider_name ? "#{provider_name}/#{model_name}" : model_name
          normalized_model = normalize_model_name(model_name)
          current = current_price_tables

          ordered_table_lookups(current).each do |source, table|
            match = explain_table(
              table: table,
              source: source,
              provider_model: provider_model,
              model_name: model_name,
              normalized_model: normalized_model
            )
            return match if match
          end
          nil
        end

        def ordered_table_lookups(current)
          [
            ["pricing_overrides", current.fetch(:pricing_overrides)],
            ["prices_file", current.fetch(:file_prices)],
            ["bundled", Registry.builtin_prices]
          ]
        end

        def current_price_tables
          cached = @prices_cache
          return cached if cached

          MUTEX.synchronize do
            cached = @prices_cache
            return cached if cached

            config = LlmCostTracker.configuration
            file_prices = Registry.file_prices(config.prices_file)
            value = { pricing_overrides: config.pricing_overrides, file_prices: file_prices }.freeze
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
            values.shift while values.size >= LOOKUP_CACHE_LIMIT
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
          Match.new(
            source: source,
            key: key,
            prices: table[key],
            matched_by: matched_by,
            currency: source_currency(source)
          )
        end

        def source_currency(source)
          raw = case source
                when "bundled" then Registry.metadata["currency"]
                when "prices_file"
                  Registry.file_metadata(LlmCostTracker.configuration.prices_file)["currency"]
                end
          (raw || Billing::DEFAULT_CURRENCY).to_s.upcase
        end

        def snapshot_variant?(model, key)
          suffix = model.delete_prefix("#{key}-")
          return false if suffix == model

          suffix.match?(/\A(?:\d{4}-\d{2}-\d{2}|\d{8})\z/)
        end

        def sorted_price_keys(table)
          cached = @sorted_price_keys_cache
          existing = cached && cached[table]
          return existing if existing

          MUTEX.synchronize do
            cached = @sorted_price_keys_cache
            existing = cached && cached[table]
            return existing if existing

            keys = table.keys.sort_by { |key| -key.length }
            next_cache = cached ? cached.dup : {}.compare_by_identity
            next_cache[table] = keys
            @sorted_price_keys_cache = next_cache.freeze
            keys
          end
        end
      end
    end
  end
end
