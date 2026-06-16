# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "registry"

module LlmCostTracker
  module Pricing
    module Matcher
      Match = Data.define(:source, :key, :prices, :matched_by)

      CACHE_LIMIT = 2048
      private_constant :CACHE_LIMIT

      class << self
        def lookup(provider:, model:)
          provider_name = provider.to_s.presence
          model_name = model.to_s
          return nil if model_name.empty?

          sources = Registry.sources
          reset_cache(sources) unless @cache_sources.equal?(sources)
          key = [provider_name, model_name].freeze
          return @cache[key] if @cache.key?(key)

          @cache.clear if @cache.size >= CACHE_LIMIT
          @cache[key] = lookup_match(sources, provider_name, model_name)
        end

        private

        def reset_cache(sources)
          @cache_sources = sources
          @cache = {}
        end

        def lookup_match(sources, provider_name, model_name)
          provider_model = provider_name ? "#{provider_name}/#{model_name}" : model_name
          normalized = normalize_model_name(model_name)

          sources.each do |source|
            match = match_in_source(source, provider_model, model_name, normalized)
            return match if match
          end
          nil
        end

        def match_in_source(source, provider_model, model_name, normalized)
          table = source.prices
          return nil if table.empty?

          [[provider_model, :provider_model], [model_name, :model], [normalized, :normalized_model]].each do |key, by|
            return build_match(source, key, by) if table.key?(key)
          end

          scan = native_keys(table)
          if (key = unique_in(scan) { |native| normalize_model_name(native) == normalized })
            return build_match(source, key, :unique_providerless_model)
          end

          dated = scan.find do |native|
            snapshot_variant?(provider_model, native) || snapshot_variant?(normalized, native)
          end
          return build_match(source, dated, :dated_snapshot) if dated

          unique_dated = unique_in(scan) { |native| snapshot_variant?(normalized, normalize_model_name(native)) }
          return build_match(source, unique_dated, :unique_providerless_dated_snapshot) if unique_dated

          nil
        end

        def unique_in(keys, &)
          matches = keys.select(&)
          matches.first if matches.one?
        end

        def normalize_model_name(model)
          model.to_s.split("/").last
        end

        def native_keys(table)
          Registry.sorted_price_keys(table).reject { |key| key.count("/") > 1 }
        end

        def build_match(source, key, matched_by)
          Match.new(source: source, key: key, prices: source.prices[key], matched_by: matched_by)
        end

        def snapshot_variant?(model, key)
          suffix = model.delete_prefix("#{key}-")
          return false if suffix == model

          suffix.match?(/\A(?:\d{4}-\d{2}-\d{2}|\d{8}|(?:preview|exp)-\d{2}-(?:\d{2}|\d{4}))\z/)
        end
      end
    end
  end
end
