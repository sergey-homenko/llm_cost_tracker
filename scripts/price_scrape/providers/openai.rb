# frozen_string_literal: true

require "json"
require "nokogiri"
require "time"

module LlmCostTracker
  module PriceScrape
    module Providers
      class Openai
        SOURCE_URL = "https://developers.openai.com/api/docs/pricing"
        MIN_MODELS_EXPECTED = 25
        MAX_PRICE_PER_MTOK = 1000.0

        MODEL_ID_BY_DISPLAY_NAME = {
          "chatgpt-4o-latest" => "chatgpt-4o-latest", "codex-mini-latest" => "codex-mini-latest",
          "gpt-3.5-turbo" => "gpt-3.5-turbo", "gpt-4" => "gpt-4", "gpt-4-0613" => "gpt-4",
          "gpt-4-turbo" => "gpt-4-turbo", "gpt-4-turbo-2024-04-09" => "gpt-4-turbo",
          "gpt-4.1" => "gpt-4.1", "gpt-4.1-mini" => "gpt-4.1-mini",
          "gpt-4.1-nano" => "gpt-4.1-nano", "gpt-4o" => "gpt-4o",
          "gpt-4o-2024-05-13" => "gpt-4o-2024-05-13", "gpt-4o-mini" => "gpt-4o-mini",
          "gpt-5" => "gpt-5", "gpt-5-chat-latest" => "gpt-5-chat-latest",
          "gpt-5-codex" => "gpt-5-codex", "gpt-5-mini" => "gpt-5-mini",
          "gpt-5-nano" => "gpt-5-nano", "gpt-5-pro" => "gpt-5-pro",
          "gpt-5.1" => "gpt-5.1", "gpt-5.1-chat-latest" => "gpt-5.1-chat-latest",
          "gpt-5.1-codex" => "gpt-5.1-codex", "gpt-5.1-codex-max" => "gpt-5.1-codex-max",
          "gpt-5.1-codex-mini" => "gpt-5.1-codex-mini", "gpt-5.2" => "gpt-5.2",
          "gpt-5.2-chat-latest" => "gpt-5.2-chat-latest", "gpt-5.2-codex" => "gpt-5.2-codex",
          "gpt-5.2-pro" => "gpt-5.2-pro", "gpt-5.3-chat-latest" => "gpt-5.3-chat-latest",
          "gpt-5.3-codex" => "gpt-5.3-codex", "gpt-5.4" => "gpt-5.4",
          "gpt-5.4 (<272K context length)" => "gpt-5.4", "gpt-5.4-mini" => "gpt-5.4-mini",
          "gpt-5.4-nano" => "gpt-5.4-nano", "gpt-5.4-pro" => "gpt-5.4-pro",
          "gpt-5.4-pro (<272K context length)" => "gpt-5.4-pro", "gpt-5.5" => "gpt-5.5",
          "gpt-5.5 (<272K context length)" => "gpt-5.5", "gpt-5.5-pro" => "gpt-5.5-pro",
          "gpt-5.5-pro (<272K context length)" => "gpt-5.5-pro", "o1" => "o1", "o1-mini" => "o1-mini",
          "o1-pro" => "o1-pro", "o3" => "o3", "o3-mini" => "o3-mini", "o3-pro" => "o3-pro",
          "o4-mini" => "o4-mini"
        }.freeze

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = merge_model_fields(extract_standard_models(doc), extract_specialized_models(doc, tier: "standard"))
          models = merge_model_fields(models, extract_batch_models(doc))
          models = merge_model_fields(models, extract_specialized_models(doc, tier: "batch"))
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: []
          )
        end

        private

        def extract_standard_models(doc)
          extract_tier_models(doc, tier: "standard", fields: standard_fields)
        end

        def extract_batch_models(doc)
          extract_tier_models(doc, tier: "batch", fields: batch_fields)
        end

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

          extract_rows(group_rows_from(props), fields: tier == "batch" ? batch_fields : standard_fields)
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

        def standard_fields
          { input: "input", cache_read_input: "cache_read_input", output: "output" }
        end

        def batch_fields
          { input: "batch_input", cache_read_input: "batch_cache_read_input", output: "batch_output" }
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
          return nil if text.empty? || text == "-"

          parse_price(value)
        end

        def unwrap(value)
          return unwrap(value[1]) if value.is_a?(Array) && value.size == 2 && value[0].is_a?(Integer)

          value
        end

        def validate!(models)
          if models.size < MIN_MODELS_EXPECTED
            raise Error, "expected at least #{MIN_MODELS_EXPECTED} models, parsed #{models.size}"
          end

          models.each do |model_id, fields|
            fields.each do |field, value|
              next if value.is_a?(Float) && value.positive? && value < MAX_PRICE_PER_MTOK

              raise Error, "invalid price for #{model_id}.#{field}: #{value.inspect}"
            end
          end
        end
      end
    end
  end
end
