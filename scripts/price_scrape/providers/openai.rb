# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"
require "nokogiri"
require "time"

require_relative "../price_fields_validator"
require_relative "openai/model_ids"
require_relative "openai/rendered_long_context_prices"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai
        SOURCE_URL = "https://developers.openai.com/api/docs/pricing"
        MIN_MODELS_EXPECTED = 25
        MAX_PRICE_PER_MTOK = 1000.0
        STANDARD_FIELDS = { input: "input", cache_read_input: "cache_read_input", output: "output" }.freeze
        BATCH_FIELDS = {
          input: "batch_input", cache_read_input: "batch_cache_read_input", output: "batch_output"
        }.freeze

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = merge_model_fields(
            extract_tier_models(doc, tier: "standard", fields: STANDARD_FIELDS),
            extract_specialized_models(doc, tier: "standard")
          )
          models = merge_model_fields(
            models,
            rendered_long_context_prices(doc, tier: "standard", fields: STANDARD_FIELDS)
          )
          models = merge_model_fields(models, extract_tier_models(doc, tier: "batch", fields: BATCH_FIELDS))
          models = merge_model_fields(models, rendered_long_context_prices(doc, tier: "batch", fields: BATCH_FIELDS))
          models = merge_model_fields(models, extract_specialized_models(doc, tier: "batch"))
          PriceFieldsValidator.call(
            models,
            minimum: MIN_MODELS_EXPECTED,
            maximum: MAX_PRICE_PER_MTOK,
            error_class: Error
          )
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: []
          )
        end

        private

        def extract_tier_models(doc, tier:, fields:)
          props = pricing_props(doc).find { |candidate| unwrap(candidate["tier"]) == tier }
          raise Error, "OpenAI #{tier} pricing table not found" unless props

          extract_rows(rows_from(props), fields: fields)
        end

        def extract_specialized_models(doc, tier:)
          root = doc.at_css("#content-switcher-specialized-pricing")
          return {} unless root

          pane = root.at_css(%([data-content-switcher-pane][data-value="#{tier}"]))
          return {} unless pane

          props = pricing_props(pane).find { |candidate| candidate.key?("groups") }
          return {} unless props

          extract_rows(group_rows_from(props), fields: tier == "batch" ? BATCH_FIELDS : STANDARD_FIELDS)
        end

        def rendered_long_context_prices(doc, tier:, fields:)
          RenderedLongContextPrices.new(doc, tier: tier, fields: fields, model_ids: MODEL_ID_BY_DISPLAY_NAME).models
        end

        def pricing_props(node)
          node.css("astro-island").filter_map do |island|
            next unless island["component-url"].to_s.include?("/pricing.")

            JSON.parse(island["props"].to_s)
          rescue JSON::ParserError => e
            raise Error, "unable to parse OpenAI pricing payload: #{e.message}"
          end
        end

        def rows_from(props)
          rows = unwrap(props["rows"])
          raise Error, "OpenAI standard pricing rows not found" unless rows.is_a?(Array)

          rows
        end

        def group_rows_from(props)
          groups = unwrap(props["groups"])
          return [] unless groups.is_a?(Array)

          groups.flat_map do |group|
            unwrapped_group = unwrap(group)
            rows = unwrap(unwrapped_group["rows"]) if unwrapped_group.is_a?(Hash)
            rows.is_a?(Array) ? rows : []
          end
        end

        def extract_rows(rows, fields:)
          rows.each_with_object({}) do |row, models|
            cells = unwrap(row)
            next unless cells.is_a?(Array) && cells.size >= 4

            model_id = normalize_model_id(unwrap(cells[0]))
            next unless model_id

            price_fields = extract_price_fields(cells, fields: fields)
            existing = models[model_id]
            if existing && existing != price_fields
              raise Error, "conflicting prices for #{model_id}: #{existing.inspect} vs #{price_fields.inspect}"
            end

            models[model_id] = price_fields
          end
        end

        def extract_price_fields(cells, fields:)
          prices = {
            fields.fetch(:input) => parse_price(unwrap(cells[1])),
            fields.fetch(:output) => parse_price(unwrap(cells[3]))
          }
          cache_read_input = parse_optional_price(unwrap(cells[2]))
          prices[fields.fetch(:cache_read_input)] = cache_read_input if cache_read_input

          if cells.size >= 7
            long_input = parse_optional_price(unwrap(cells[4]))
            long_cache_read = parse_optional_price(unwrap(cells[5]))
            long_output = parse_optional_price(unwrap(cells[6]))
            if long_input && long_output
              prices["_context_price_threshold_tokens"] = 272_000
              prices["above_context_#{fields.fetch(:input)}"] = long_input
              prices["above_context_#{fields.fetch(:output)}"] = long_output
              prices["above_context_#{fields.fetch(:cache_read_input)}"] = long_cache_read if long_cache_read
            end
          end
          prices
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

        def normalize_model_id(display_name)
          MODEL_ID_BY_DISPLAY_NAME[display_name.to_s.strip]
        end

        def parse_price(value)
          return Float(value) if value.is_a?(Numeric)

          if value.is_a?(Hash) && value.key?("__pricingHtml")
            return parse_price(Nokogiri::HTML.fragment(unwrap(value["__pricingHtml"]).to_s).text.strip)
          end

          match = value.to_s.match(/\A\$?\s*(\d+(?:\.\d+)?)\z/)
          raise Error, "unable to parse price #{value.inspect}" unless match

          Float(match[1])
        end

        def parse_optional_price(value)
          text = value.to_s.strip
          return nil if text.blank? || text == "-"

          parse_price(value)
        end

        def unwrap(value)
          return unwrap(value[1]) if value.is_a?(Array) && value.size == 2 && value[0].is_a?(Integer)

          value
        end
      end
    end
  end
end
