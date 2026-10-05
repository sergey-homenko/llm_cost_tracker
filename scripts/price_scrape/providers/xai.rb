# frozen_string_literal: true

require "time"

require_relative "base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Xai < Base
        source_url "https://docs.x.ai/developers/pricing.md"
        min_models 5
        max_price 1000.0
        anchors "grok-4.7", "grok-4.3"

        MODEL_PAGE = "https://docs.x.ai/developers/models/%s.md"
        TEXT_TABLE = /^### Text API Pricing$(.+?)(?=^#)/m
        HEADER = %r{\A\| Model \| Context \| Input / 1M tokens \| Cached input / 1M tokens \| Output / 1M tokens \|\z}
        PRICE_ROW = /
          \A\|\s(?<model>[a-z0-9][a-z0-9.-]*)(?:\s\((?<bound><|≥)\s(?<thousands>\d+)k\sprompt\stokens\))?\s\|[^|]+\|
          \s\$(?<input>\d+(?:\.\d+)?)\s\|\s\$(?<cached>\d+(?:\.\d+)?)\s\|\s\$(?<output>\d+(?:\.\d+)?)\s\|\z
        /x
        BATCH_DISCOUNT = /\*\*(\d+(?:\.\d+)?)% off standard rates\*\*\s+((?:- \S+\s+)+)/
        REGIONAL_SECTION = /^## US Regional Endpoint Pricing$(.+?)(?=^## |\z)/m
        ALIASES = /^- \*\*Aliases:\*\*(.*)$/

        def self.followup_urls(pages)
          price_rows(pages.fetch(source_url)).map { |row| format(MODEL_PAGE, row[:model]) }.uniq
        end

        def self.price_rows(pricing)
          header, _, *rows = pricing[TEXT_TABLE, 1].to_s.lines.map(&:strip).grep(/\A\|/)
          raise Error, "xai text price table not found" unless header&.match?(HEADER) && rows.any?

          rows.map { |line| PRICE_ROW.match(line) || raise(Error, "xai price row not understood: #{line}") }
        end

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          pricing = html.fetch(self.class.source_url)
          models = with_tiers(text_prices(pricing), pricing)
          models = models.each_with_object(models.dup) do |(model, fields), priced|
            html.fetch(format(MODEL_PAGE, model))[ALIASES, 1].to_s.scan(/`([^`]+)`/).flatten.each do |id|
              raise Error, "xai lists #{id} twice" if priced.key?(id)

              priced[id] = fields
            end
          end
          validate!(models)
          Result.new(source_url:, scraped_at:, models:, deprecated_models: [], service_charges: {})
        end

        private

        def text_prices(pricing)
          self.class.price_rows(pricing).group_by { |row| row[:model] }.to_h do |model, (low, high, *rest)|
            next [model, prices(low)] unless low[:bound] || high

            unless rest.empty? && low[:bound] == "<" && high&.[](:bound) == "≥" && high[:thousands] == low[:thousands]
              raise Error, "xai long-context rows for #{model} not understood"
            end

            above = prices(high).transform_keys { |field| "above_context_#{field}" }
            threshold = (Integer(low[:thousands]) * 1000) - 1
            [model, prices(low).merge(above, "_context_price_threshold_tokens" => threshold)]
          end
        end

        def prices(row)
          { "input" => Float(row[:input]), "cache_read_input" => Float(row[:cached]), "output" => Float(row[:output]) }
        end

        def with_tiers(models, pricing)
          priority = documented_factor(pricing, /billed at a \*\*([\d.]+)x\*\* premium/, "priority")
          regional = pricing[REGIONAL_SECTION, 1]
          uplift = documented_factor(regional, /billed at \*\*([\d.]+)x\*\*/, "US regional")
          regional_models = regional[/^\| Models \|.*\|(.*)\|$/, 1].to_s.scan(/`([^`]+)`/).flatten
          raise Error, "xai US regional models not found in its docs" if regional_models.empty?

          unpriced = regional_models - models.keys
          raise Error, "xai US regional models #{unpriced.join(', ')} are missing from its price table" if unpriced.any?

          batch = batch_factors(pricing, models)
          models.to_h do |id, fields|
            images = fields.slice("input", "above_context_input")
            tiered = fields.merge(images.transform_keys { |key| key.sub("input", "image_input") },
                                  tier_prices(fields, "priority", priority))
            if regional_models.include?(id)
              tiered = tiered.merge(tier_prices(fields, "data_residency", uplift),
                                    tier_prices(fields, "priority_data_residency", priority * uplift))
            end
            [id, batch.key?(id) ? tiered.merge(tier_prices(fields, "batch", batch[id])) : tiered]
          end
        end

        def batch_factors(pricing, models)
          discounts = pricing.scan(BATCH_DISCOUNT).flat_map do |percent, list|
            list.scan(/- (\S+)/).flatten.map { |model| [model, 1 - (Float(percent) / 100)] }
          end
          raise Error, "xai batch discounts not found in its docs" if discounts.empty?

          unpriced = discounts.map(&:first) - models.keys
          raise Error, "xai lists a batch discount for #{unpriced.join(', ')} outside its price table" if unpriced.any?

          discounts.to_h
        end
      end
    end
  end
end
