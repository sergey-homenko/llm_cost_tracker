# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"
require_relative "openai/catalogue"
require_relative "openai/data_residency_prices"
require_relative "openai/deprecated_models"
require_relative "openai/price_rows"
require_relative "openai/pricing_page"
require_relative "openai/rendered_long_context_prices"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        source_url "https://developers.openai.com/api/docs/pricing"
        min_models 25
        max_price 1000.0
        anchors "gpt-5.5", "gpt-5.4-mini"
        MODEL_CATALOGUE_URL = "https://developers.openai.com/api/docs/models/all.md"
        BATCH_GUIDE_URL = "https://developers.openai.com/api/docs/guides/batch.md"
        SOURCE_URLS = [
          source_url,
          RenderedLongContextPrices::SOURCE_URL,
          DeprecatedModels::SOURCE_URL,
          MODEL_CATALOGUE_URL,
          BATCH_GUIDE_URL,
          *DataResidencyPrices::SOURCE_URLS
        ].freeze
        MODEL_ID_ALIASES = {
          "gpt-4" => "gpt-4-0613", "gpt-4-turbo" => "gpt-4-turbo-2024-04-09",
          "omni-moderation-2024-09-26" => "omni-moderation-latest",
          "text-embedding-ada-002-v2" => "text-embedding-ada-002"
        }.freeze
        BATCH_DISCOUNT = /(\d+)% cost discount compared to synchronous APIs/
        TOOL_PRICES = {
          "web_search_request" => "Web search",
          "web_search_preview_request_reasoning" => "Web search preview (reasoning models, including gpt-5, o-series)",
          "web_search_preview_request_non_reasoning" => "Web search preview (non-reasoning models)",
          "file_search_call" => "Tool call"
        }.freeze
        REQUIRED_TOOL_PRICES = %w[web_search_request file_search_call].freeze

        def self.prefixed_fields(prefix, columns = %i[input cache_read_input cache_write_input output])
          columns.to_h { |column| [column, "#{prefix}#{column}"] }.freeze
        end
        private_class_method :prefixed_fields

        STANDARD_FIELDS = prefixed_fields("")
        TIER_FIELDS = {
          "standard" => STANDARD_FIELDS, "batch" => prefixed_fields("batch_"), "flex" => prefixed_fields("flex_"),
          "fast" => prefixed_fields("fast_"), "ultrafast" => prefixed_fields("ultrafast_")
        }.freeze
        AUDIO_FIELDS = prefixed_fields("audio_", %i[input cache_read_input output])
        TIER_IMAGE_FIELDS = {
          STANDARD_FIELDS => prefixed_fields("image_", %i[input cache_read_input output]),
          TIER_FIELDS.fetch("batch") => prefixed_fields("batch_image_", %i[input cache_read_input output])
        }.freeze
        FAST_FIELD = /(?<![a-z])fast_/

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          pages = pages_from(html)
          page = PricingPage.new(Nokogiri::HTML(pages.fetch(self.class.source_url)))
          models, notes = priced_models(page, pages)
          validate!(models)
          Result.new(
            source_url:,
            scraped_at:,
            models:,
            deprecated_models: deprecated_models(pages, scraped_at:),
            service_charges: service_charges(page),
            notes:
          )
        end

        private

        def pages_from(html)
          return html.transform_keys(&:to_s) if html.is_a?(Hash)

          SOURCE_URLS.to_h { |url| [url, html.to_s] }
        end

        def priced_models(page, pages)
          @catalogue = Catalogue.new(pages[MODEL_CATALOGUE_URL])
          @price_rows = PriceRows.new(@catalogue)
          models = TIER_FIELDS.keys.reduce({}) do |collected, tier|
            merge_model_fields(collected, tier_models(page, pages, tier))
          end
          models = merge_model_fields(models, batch_embedding_prices(models, pages))
          models, notes = DataResidencyPrices.call(models, pages)
          [add_model_id_aliases(add_priority_aliases(models)), notes]
        end

        def tier_models(page, pages, tier)
          fields = TIER_FIELDS.fetch(tier)
          rows = @price_rows.models(page.tier_rows(tier), fields)
          models = merge_model_fields(rows, long_context_models(pages, tier, fields))
          merge_model_fields(models, specialized_models(page, tier, fields))
        end

        def long_context_models(pages, tier, fields)
          markdown = pages.fetch(RenderedLongContextPrices::SOURCE_URL)
          RenderedLongContextPrices.new(markdown, tier:, fields:, model_ids: @catalogue.method(:model_id)).models
        end

        def specialized_models(page, tier, fields)
          groups = page.specialized_groups(tier)
          tiered = groups ? pane_models(groups, fields) : {}
          untiered = page.untiered_groups(tier).reduce({}) do |models, island_groups|
            merge_model_fields(models, @price_rows.grouped_models(island_groups, fields))
          end
          merge_model_fields(tiered, untiered)
        end

        def pane_models(groups, fields)
          rows = @price_rows.models(@price_rows.group_rows(groups), fields)
          merge_model_fields(rows, @price_rows.grouped_models(groups, fields))
        end

        def batch_embedding_prices(models, pages)
          discount = documented_factor(pages.fetch(BATCH_GUIDE_URL), BATCH_DISCOUNT, "Batch API discount")
          models.select { |model_id, _| model_id.start_with?("text-embedding-") }
                .transform_values { |fields| tier_prices(fields, "batch", 1 - (discount / 100)) }
        end

        def add_priority_aliases(models)
          models.each_with_object({}) do |(model_id, fields), aliased|
            aliased[model_id] = fields.merge(priority_alias_fields(fields))
          end
        end

        def priority_alias_fields(fields)
          fields.each_with_object({}) do |(field, value), aliases|
            aliases[field.sub(FAST_FIELD, "priority_")] = value if field.match?(FAST_FIELD)
          end
        end

        def add_model_id_aliases(models)
          MODEL_ID_ALIASES.each_with_object(models.dup) do |(alias_id, model_id), aliased|
            aliased[alias_id] ||= models[model_id] if models.key?(model_id)
          end
        end

        def merge_model_fields(left, right)
          left.merge(right) do |model_id, existing, incoming|
            conflicts = incoming.select { |field, value| existing.key?(field) && existing[field] != value }
            if conflicts.any?
              raise Error, "conflicting prices for #{model_id}: #{existing.inspect} vs #{incoming.inspect}"
            end

            existing.merge(incoming)
          end
        end

        def deprecated_models(pages, scraped_at:)
          doc = Nokogiri::HTML(pages.fetch(DeprecatedModels::SOURCE_URL))
          DeprecatedModels.call(doc, scraped_on: Date.parse(scraped_at))
        end

        def service_charges(page)
          rows = page.tool_rows
          TOOL_PRICES.each_with_object({}) do |(charge, label), charges|
            row = rows.find { |cells| cells.first == label }
            if row
              charges[charge] = parse_service_charge_price(row.last)
            elsif REQUIRED_TOOL_PRICES.include?(charge)
              raise Error, "OpenAI tool price #{label.inspect} not found"
            end
          end
        end

        def parse_service_charge_price(text)
          match = text.match(/\$\s*(\d+(?:\.\d+)?)/)
          raise Error, "unable to parse service charge price #{text.inspect}" unless match

          Float(match[1])
        end
      end
    end
  end
end
