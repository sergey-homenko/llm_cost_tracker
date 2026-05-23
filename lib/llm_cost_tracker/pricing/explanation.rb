# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    Explanation = Data.define(
      :provider, :model, :pricing_mode, :source, :matched_key, :matched_by,
      :prices, :effective_prices, :missing_price_keys
    ) do
      def self.from_lookup(provider:, model:, match:, mode:, effective:)
        effective ||= {}
        new(
          provider: provider.to_s, model: model.to_s, pricing_mode: mode,
          source: match&.source, matched_key: match&.key, matched_by: match&.matched_by,
          prices: match&.prices, effective_prices: effective,
          missing_price_keys: effective.filter_map { |key, value| key if value.nil? }
        )
      end

      def matched?
        !prices.nil?
      end

      def complete?
        matched? && missing_price_keys.empty?
      end

      def message
        return "No price entry matched #{provider}/#{model}" unless matched?
        return "Matched #{matched_key} from #{source} via #{matched_by}" if complete?

        "Matched #{matched_key} from #{source} via #{matched_by}, but missing #{missing_price_keys.join(', ')}"
      end
    end
  end
end
