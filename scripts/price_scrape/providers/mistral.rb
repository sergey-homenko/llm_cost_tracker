# frozen_string_literal: true

require "nokogiri"

require_relative "litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Mistral < Litellm
        source_url SOURCE_URL
        litellm_provider "mistral"
        min_models 10
        max_price 1000.0
        anchors "mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"

        PRICING_SOURCE_URL = "https://docs.mistral.ai/inference/pricing"
        TIER_SOURCES = {
          "batch" => ["https://docs.mistral.ai/studio/batch-processing.md", /at a (\d+)% discount/],
          "priority" => ["https://docs.mistral.ai/inference/priority-tier.md",
                         /multiplier is ([\d.]+)x standard list pricing/],
          "data_residency" => ["https://docs.mistral.ai/inference/regional-inference.md",
                               /billed at \*\*([\d.]+)[x×] standard list pricing/]
        }.freeze
        SOURCE_URLS = [source_url, PRICING_SOURCE_URL, *TIER_SOURCES.values.map(&:first)].freeze
        PRICE_COLUMNS = { "Input" => "input", "Cached input" => "cache_read_input", "Output" => "output" }.freeze
        MODEL_CARD = %r{\Ahttps://docs\.mistral\.ai/models/(?:model-cards/)?(?<card>[a-z0-9-]+)\z}
        TOKEN_PRICE = /\A\$(?<amount>\d+(?:\.\d+)?)\z/

        def call(html:, **)
          @listed = listed_prices(Nokogiri::HTML(html.fetch(PRICING_SOURCE_URL)))
          @cards_by_stem = cards_by_stem(@listed.keys)
          @tier_factors = TIER_SOURCES.to_h do |tier, (url, pattern)|
            factor = documented_factor(html.fetch(url), pattern, tier)
            [tier, tier == "batch" ? 1 - (factor / 100) : factor]
          end
          super(html: html.fetch(self.class.source_url), **)
        end

        private

        # Batch, Priority Tier and the regional endpoints (api.eu/us.mistral.ai) bill a documented multiple of standard;
        # Mistral publishes no rate for Priority Tier on a regional endpoint, so it compounds the two.
        def with_tiers(models)
          tiers = @tier_factors.merge(
            "priority_data_residency" => @tier_factors.fetch("priority") * @tier_factors.fetch("data_residency")
          )
          models.transform_values do |fields|
            tiers.reduce(fields) { |priced, (tier, factor)| priced.merge(tier_prices(fields, tier, factor)) }
          end
        end

        def extract_fields(key, entry)
          card = MODEL_CARD.match(entry["source"].to_s)&.[](:card) ||
                 @cards_by_stem[key.delete_prefix("mistral/")[/\A(.+)-(?:latest|\d{4})\z/, 1]]
          @listed.fetch(card, {})
        end

        # LiteLLM points some API names at the pricing page rather than a model card. Those match the one
        # card named like them, so ministral-8b-2512 and ministral-8b-latest take ministral-3-8b-25-12.
        def cards_by_stem(cards)
          cards.group_by { |card| card.sub(/-\d{2}-\d{2}\z/, "").split("-").grep_v(/\A\d+\z/).join("-") }
               .filter_map { |stem, group| [stem, group.first] if group.one? }.to_h
        end

        def listed_prices(doc)
          doc.css("table").each_with_object({}) do |table, listed|
            fields = table.css("th").map { |header| PRICE_COLUMNS[header.text.strip] }
            table.css("tr").each do |row|
              link = row.at_css("a[href^='/models/']")
              prices = fields.zip(row.css("td")).filter_map do |field, cell|
                amount = field && cell && TOKEN_PRICE.match(cell.text.strip)
                [field, Float(amount[:amount])] if amount
              end.to_h
              listed[link["href"].delete_prefix("/models/")] = prices if link
            end
          end
        end
      end
    end
  end
end
