# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "date"

require_relative "registry"

module LlmCostTracker
  module Pricing
    module Matcher
      Match = Data.define(:source, :key, :prices, :matched_by)

      CACHE_LIMIT = 2048
      BEDROCK_ANTHROPIC_ID = /\A(?:[a-z]+\.)?anthropic\.(claude-.+?)(?:-v\d+(?::\d+)?)?\z/
      private_constant :CACHE_LIMIT, :BEDROCK_ANTHROPIC_ID

      class << self
        def lookup(provider:, model:, at: Time.now)
          provider_name = provider.to_s.presence
          model_name = model.to_s
          return nil if model_name.empty?

          sources = Registry.sources
          reset_cache(sources) unless @cache_sources.equal?(sources)
          date = at.getutc.to_date.iso8601
          key = [provider_name, model_name, date].freeze
          return @cache[key] if @cache.key?(key)

          @cache.clear if @cache.size >= CACHE_LIMIT
          @cache[key] = lookup_match(sources, provider_name, model_name)&.then do |match|
            match.with(prices: prices_on(match.prices, date))
          end
        end

        def prices_on(prices, date)
          scheduled = prices.keys.grep(PriceKey::SCHEDULED_SUFFIX)
          return prices if scheduled.empty?

          current = prices.except(*scheduled)
          scheduled.sort_by { |key| key[PriceKey::SCHEDULED_SUFFIX, 1] }.each do |key|
            from = key[PriceKey::SCHEDULED_SUFFIX, 1]
            current[key.delete_suffix("_from_#{from}")] = prices[key] if from <= date
          end
          current.freeze
        end

        def modifier_priced?(provider:, model:, modifier:)
          prices = lookup(provider: provider, model: model)&.prices
          return false unless prices

          prices.any? { |key, _| key.to_s.match?(/(?:\A|_)#{modifier}_/) }
        end

        private

        def reset_cache(sources)
          @cache_sources = sources
          @cache = {}
        end

        def lookup_match(sources, provider_name, model_name)
          provider_model = provider_name ? "#{provider_name}/#{model_name}" : model_name
          normalized = normalize_model_name(model_name)

          live = sources.reject { |source| source.prices.empty? }
          live.lazy.filter_map { |source| exact_match(source, provider_model, model_name, normalized) }.first ||
            live.lazy.filter_map { |source| fallback_match(source, normalized) }.first
        end

        def exact_match(source, provider_model, model_name, normalized)
          table = source.prices
          [[provider_model, :provider_model], [model_name, :model], [normalized, :normalized_model]].each do |key, by|
            return build_match(source, key, by) if table.key?(key)
          end

          dated = native_keys(table).find do |native|
            snapshot_variant?(provider_model, native) || snapshot_variant?(normalized, native)
          end
          build_match(source, dated, :dated_snapshot) if dated
        end

        def fallback_match(source, normalized)
          scan = native_keys(source.prices)
          if (key = unique_in(scan) { |native| normalize_model_name(native) == normalized })
            return build_match(source, key, :unique_providerless_model)
          end

          unique_dated = unique_in(scan) { |native| snapshot_variant?(normalized, normalize_model_name(native)) }
          build_match(source, unique_dated, :unique_providerless_dated_snapshot) if unique_dated
        end

        def unique_in(keys, &)
          matches = keys.select(&)
          matches.first if matches.one?
        end

        def normalize_model_name(model)
          name = model.to_s.split("/").last
          name.match(BEDROCK_ANTHROPIC_ID)&.[](1) || name
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
