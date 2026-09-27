# frozen_string_literal: true

require_relative "litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Xai < Litellm
        source_url SOURCE_URL
        litellm_provider "xai"
        min_models 5
        max_price 1000.0
        anchors "grok-4.7", "grok-4.3"

        DOCS_URL = "https://docs.x.ai/developers"
        PRICING_SOURCE_URL = "#{DOCS_URL}/pricing.md".freeze
        # Model pages list the aliases that share a model's batch discount; the pricing page names the models.
        BATCH_MODEL_URLS = %w[grok-4.3 grok-4.20-0309-reasoning grok-4.20-0309-non-reasoning grok-4.20-multi-agent-0309]
                           .to_h { |model| [model, "#{DOCS_URL}/models/#{model}.md"] }.freeze
        SOURCE_URLS = [source_url, PRICING_SOURCE_URL, *BATCH_MODEL_URLS.values].freeze
        BATCH_DISCOUNT = /\*\*(\d+)% off standard rates\*\*\s+((?:- \S+\s+)+)/
        INCLUSIVE_THRESHOLD = /\(≥ (\d+)k prompt tokens\)/
        REGIONAL_SECTION = /^## US Regional Endpoint Pricing$(.+?)(?=^## |\z)/m

        def call(html:, **)
          @pages = html
          super(html: html.fetch(self.class.source_url), **)
        end

        private

        def with_tiers(models)
          pricing = @pages.fetch(PRICING_SOURCE_URL)
          priority = documented_factor(pricing, /billed at a \*\*([\d.]+)x\*\* premium/, "priority")
          regional = pricing[REGIONAL_SECTION, 1]
          uplift = documented_factor(regional, /billed at \*\*([\d.]+)x\*\*/, "US regional")
          regional_models = regional[/^\| Models \|.*\|(.*)\|$/, 1].to_s.scan(/`([^`]+)`/).flatten
          raise Error, "xai US regional models not found in its docs" if regional_models.empty?

          # xAI bills the long-context rate from the threshold itself ("≥ 200k prompt tokens"); the gem
          # applies it above the stored threshold.
          inclusive = pricing.scan(INCLUSIVE_THRESHOLD).flatten.map { |thousands| Integer(thousands) * 1000 }
          batch_prices(models, pricing).to_h do |id, fields|
            # xAI bills image prompt tokens at the model's one listed input rate.
            images = fields.slice("input", "above_context_input")
            fields = fields.merge(images.transform_keys { |key| key.sub("input", "image_input") })
            fields = fields.merge(tier_prices(fields, "priority", priority))
            if regional_models.include?(id)
              fields = fields.merge(tier_prices(fields, "data_residency", uplift))
                             .merge(tier_prices(fields, "priority_data_residency", priority * uplift))
            end
            threshold = fields["_context_price_threshold_tokens"]
            fields = fields.merge("_context_price_threshold_tokens" => threshold - 1) if inclusive.include?(threshold)
            [id, fields]
          end
        end

        def batch_prices(models, pricing)
          discounts = pricing.scan(BATCH_DISCOUNT).flat_map do |percent, list|
            list.scan(/- (\S+)/).flatten.map { |model| [model, 1 - (Float(percent) / 100)] }
          end
          raise Error, "xai batch discounts not found in its docs" if discounts.empty?

          discounts.each_with_object(models.dup) do |(model, factor), priced|
            url = BATCH_MODEL_URLS.fetch(model) do
              raise Error, "xai lists a batch discount for #{model}; add its model page to BATCH_MODEL_URLS"
            end
            aliases = @pages.fetch(url)[/^- \*\*Aliases:\*\*(.*)$/, 1].to_s.scan(/`([^`]+)`/).flatten
            [model, *aliases].each do |id|
              priced[id] = priced[id].merge(tier_prices(priced[id], "batch", factor)) if priced.key?(id)
            end
          end
        end
      end
    end
  end
end
