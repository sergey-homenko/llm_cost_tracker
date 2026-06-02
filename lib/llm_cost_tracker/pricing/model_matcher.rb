# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "match"
require_relative "registry"

module LlmCostTracker
  module Pricing
    module ModelMatcher
      class << self
        def lookup(provider:, model:)
          provider_name = provider.to_s.presence
          model_name = model.to_s
          return nil if model_name.empty?

          lookup_match(provider_name: provider_name, model_name: model_name)
        end

        private

        def lookup_match(provider_name:, model_name:)
          provider_model = provider_name ? "#{provider_name}/#{model_name}" : model_name
          normalized = normalize_model_name(model_name)

          first_match(Registry.price_tables) do |table, source|
            match_in_table(table, source, provider_model, model_name, normalized)
          end
        end

        def first_match(sources)
          sources.each do |source, table|
            result = yield(table, source)
            return result if result
          end
          nil
        end

        def match_in_table(table, source, provider_model, model_name, normalized)
          return nil if table.empty?

          [[provider_model, :provider_model], [model_name, :model], [normalized, :normalized_model]].each do |key, by|
            return build_match(table, source, key, by) if table.key?(key)
          end

          scan = native_keys(table)
          if (key = unique_in(scan) { |native| normalize_model_name(native) == normalized })
            return build_match(table, source, key, :unique_providerless_model)
          end

          dated = scan.find do |native|
            snapshot_variant?(provider_model, native) || snapshot_variant?(normalized, native)
          end
          return build_match(table, source, dated, :dated_snapshot) if dated

          unique_dated = unique_in(scan) { |native| snapshot_variant?(normalized, normalize_model_name(native)) }
          return build_match(table, source, unique_dated, :unique_providerless_dated_snapshot) if unique_dated

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

        def build_match(table, source, key, matched_by)
          Match.new(
            source: source,
            key: key,
            prices: table[key],
            matched_by: matched_by,
            currency: Registry.source_currency(source)
          )
        end

        def snapshot_variant?(model, key)
          suffix = model.delete_prefix("#{key}-")
          return false if suffix == model

          suffix.match?(/\A(?:\d{4}-\d{2}-\d{2}|\d{8}|(?:preview|exp)-\d{2}-\d{2})\z/)
        end
      end
    end
  end
end
