# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"
require "nokogiri"
require "time"

require_relative "../price_fields_validator"
require_relative "openai/data_residency_prices"
require_relative "openai/model_ids"
require_relative "openai/rendered_long_context_prices"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai
        SOURCE_URL = "https://developers.openai.com/api/docs/pricing"
        MIN_MODELS_EXPECTED = 25
        MAX_PRICE_PER_MTOK = 1000.0
        ANCHOR_MODELS = %w[gpt-5.5 gpt-5.4-mini].freeze
        STANDARD_FIELDS = { input: "input", cache_read_input: "cache_read_input", output: "output" }.freeze
        BATCH_FIELDS = {
          input: "batch_input", cache_read_input: "batch_cache_read_input", output: "batch_output"
        }.freeze
        FLEX_FIELDS = {
          input: "flex_input", cache_read_input: "flex_cache_read_input", output: "flex_output"
        }.freeze
        PRIORITY_FIELDS = {
          input: "priority_input", cache_read_input: "priority_cache_read_input", output: "priority_output"
        }.freeze
        AUDIO_FIELDS = { input: "audio_input", output: "audio_output" }.freeze
        IMAGE_FIELDS = { input: "image_input", output: "image_output" }.freeze
        BATCH_IMAGE_FIELDS = { input: "batch_image_input", output: "batch_image_output" }.freeze
        TIER_FIELDS = {
          "standard" => STANDARD_FIELDS,
          "batch" => BATCH_FIELDS,
          "flex" => FLEX_FIELDS,
          "priority" => PRIORITY_FIELDS
        }.freeze
        TIER_IMAGE_FIELDS = { STANDARD_FIELDS => IMAGE_FIELDS, BATCH_FIELDS => BATCH_IMAGE_FIELDS }.freeze

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = TIER_FIELDS.each_with_object({}) do |(tier, fields), collected|
            tier_models = extract_tier_models(doc, tier: tier, fields: fields)
            tier_models = merge_model_fields(tier_models, rendered_long_context_prices(doc, tier: tier, fields: fields))
            tier_models = merge_model_fields(tier_models, extract_specialized_models(doc, tier: tier))
            collected.replace(merge_model_fields(collected, tier_models))
          end
          models = DataResidencyPrices.call(models)
          PriceFieldsValidator.call(
            models,
            minimum: MIN_MODELS_EXPECTED,
            maximum: MAX_PRICE_PER_MTOK,
            anchors: ANCHOR_MODELS,
            error_class: Error
          )
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: [],
            service_charges: extract_service_charges(doc)
          )
        end

        private

        def extract_service_charges(doc)
          table = doc.css("table").find { |candidate| candidate.text.include?("ToolDetailsPricing") }
          raise Error, "OpenAI tool pricing table not found" unless table

          rows = table.css("tbody tr").map { |tr| tr.css("td").map { |td| td.text.gsub(/\s+/, " ").strip } }
          {
            "web_search_request" => tool_price(rows, "Web search", required: true),
            "web_search_preview_request_reasoning" => tool_price(
              rows, "Web search preview (reasoning models, including gpt-5, o-series)"
            ),
            "web_search_preview_request_non_reasoning" => tool_price(
              rows, "Web search preview (non-reasoning models)"
            ),
            "file_search_call" => tool_price(rows, "Tool call", required: true)
          }.compact
        end

        def tool_price(rows, label, required: false)
          row = rows.find { |cells| cells.first == label }
          unless row
            raise Error, "OpenAI tool price #{label.inspect} not found" if required

            return nil
          end

          parse_service_charge_price(row.last)
        end

        def parse_service_charge_price(text)
          match = text.match(/\$\s*(\d+(?:\.\d+)?)/)
          raise Error, "unable to parse service charge price #{text.inspect}" unless match

          Float(match[1])
        end

        def extract_tier_models(doc, tier:, fields:)
          props = pricing_props(doc).find { |candidate| unwrap(candidate["tier"]) == tier }
          raise Error, "OpenAI #{tier} pricing table not found" unless props

          extract_rows(rows_from(props), fields: fields)
        end

        def extract_specialized_models(doc, tier:)
          fields = TIER_FIELDS.fetch(tier)
          root = doc.at_css("#content-switcher-specialized-pricing")
          return extract_untiered_grouped_models(doc, fields: fields) unless root

          pane = root.at_css(%([data-content-switcher-pane][data-value="#{tier}"]))
          return extract_untiered_grouped_models(doc, fields: fields) unless pane

          props = pricing_props(pane).find { |candidate| candidate.key?("groups") }
          tiered_models = {}
          if props
            groups = groups_from(props)
            tiered_models = merge_model_fields(
              extract_rows(group_rows_from(groups), fields: fields),
              extract_grouped_rows(groups, fields: fields)
            )
          end

          merge_model_fields(tiered_models, extract_untiered_grouped_models(doc, fields: fields))
        end

        def rendered_long_context_prices(doc, tier:, fields:)
          RenderedLongContextPrices.new(doc, tier: tier, fields: fields, model_ids: MODEL_ID_BY_DISPLAY_NAME).models
        end

        def extract_untiered_grouped_models(doc, fields:)
          doc.css("astro-island").each_with_object({}) do |island, models|
            next unless island["component-url"].to_s.include?("/pricing.")
            next unless island_matches_tier?(island, fields)

            props = parse_island_props(island)
            next if props.key?("tier")

            grouped_models = extract_grouped_rows(groups_from(props), fields: fields)
            models.replace(merge_model_fields(models, grouped_models))
          end
        end

        def island_matches_tier?(island, fields)
          pane = island.ancestors("[data-content-switcher-pane]").first
          pane_value = pane && pane["data-value"]
          TIER_FIELDS.fetch(pane_value || "standard", STANDARD_FIELDS) == fields
        end

        def pricing_props(node)
          node.css("astro-island").filter_map do |island|
            next unless island["component-url"].to_s.include?("/pricing.")

            parse_island_props(island)
          end
        end

        def parse_island_props(island)
          JSON.parse(island["props"].to_s)
        rescue JSON::ParserError => e
          raise Error, "unable to parse OpenAI pricing payload: #{e.message}"
        end

        def rows_from(props)
          rows = unwrap(props["rows"])
          raise Error, "OpenAI standard pricing rows not found" unless rows.is_a?(Array)

          rows
        end

        def groups_from(props)
          groups = unwrap(props["groups"])
          groups.is_a?(Array) ? groups : []
        end

        def group_rows_from(groups)
          groups.flat_map do |group|
            group = unwrap(group)
            rows = unwrap(group["rows"]) if group.is_a?(Hash)
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

        def extract_grouped_rows(groups, fields:)
          groups.each_with_object({}) do |group, models|
            group = unwrap(group)
            next unless group.is_a?(Hash)

            model_id = normalize_model_id(unwrap(group["model"]))
            next unless model_id

            rows = unwrap(group["rows"])
            next unless rows.is_a?(Array)

            price_fields = group_price_fields(rows, fields: fields)
            models[model_id] = price_fields if price_fields.any?
          end
        end

        def group_price_fields(rows, fields:)
          rows.each_with_object({}) do |row, values|
            cells = unwrap(row)
            next unless cells.is_a?(Array) && cells.size >= 4

            modality_fields = modality_fields_for(unwrap(cells[0]), fields: fields)
            values.merge!(extract_price_fields(cells, fields: modality_fields)) if modality_fields
          end
        end

        def modality_fields_for(modality, fields:)
          case modality
          when "Text" then fields
          when "Audio" then AUDIO_FIELDS
          when "Image" then TIER_IMAGE_FIELDS[fields]
          end
        end

        def extract_price_fields(cells, fields:)
          prices = { fields.fetch(:input) => parse_price(unwrap(cells[1])) }
          output = parse_optional_price(unwrap(cells[3]))
          prices[fields.fetch(:output)] = output if output
          cache_read_input = parse_optional_price(unwrap(cells[2]))
          prices[fields.fetch(:cache_read_input)] = cache_read_input if cache_read_input && fields[:cache_read_input]

          if cells.size >= 7
            long_input = parse_optional_price(unwrap(cells[4]))
            long_cache_read = parse_optional_price(unwrap(cells[5]))
            long_output = parse_optional_price(unwrap(cells[6]))
            if long_input && long_output
              prices["_context_price_threshold_tokens"] = 272_000
              prices["above_context_#{fields.fetch(:input)}"] = long_input
              prices["above_context_#{fields.fetch(:output)}"] = long_output
              if long_cache_read && fields[:cache_read_input]
                prices["above_context_#{fields.fetch(:cache_read_input)}"] = long_cache_read
              end
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
