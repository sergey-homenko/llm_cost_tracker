# frozen_string_literal: true

require "nokogiri"
require "time"

require_relative "../price_fields_validator"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Groq
        SOURCE_URL = "https://console.groq.com/docs/models"
        PROMPT_CACHING_SOURCE_URL = "https://console.groq.com/docs/prompt-caching"
        FLEX_PROCESSING_SOURCE_URL = "https://console.groq.com/docs/flex-processing"
        SOURCE_URLS = [SOURCE_URL, PROMPT_CACHING_SOURCE_URL, FLEX_PROCESSING_SOURCE_URL].freeze
        MIN_MODELS_EXPECTED = 4
        MAX_PRICE_PER_MTOK = 1000.0

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          pages = pages_from(html)
          models_doc = Nokogiri::HTML(pages.fetch(SOURCE_URL))
          prompt_caching_doc = Nokogiri::HTML(pages.fetch(PROMPT_CACHING_SOURCE_URL))
          flex_doc = Nokogiri::HTML(pages.fetch(FLEX_PROCESSING_SOURCE_URL))

          verify_prompt_cache_discount!(prompt_caching_doc)
          verify_flex_pricing!(flex_doc)

          cache_models = extract_prompt_cache_models(prompt_caching_doc)
          models = extract_models(models_doc, cache_models: cache_models)
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

        def pages_from(html)
          return html.transform_keys(&:to_s) if html.is_a?(Hash)

          SOURCE_URLS.to_h { |url| [url, html.to_s] }
        end

        def extract_models(doc, cache_models:)
          table = find_production_models_table(doc)
          raise Error, "Groq production models pricing table not found" unless table

          headers = header_texts(table)
          model_index = column_index(headers, "MODEL ID")
          price_index = column_index(headers, "PRICE PER 1M TOKENS")

          table.css("tbody tr").each_with_object({}) do |row, models|
            cells = row.css("td")
            next unless cells.size > [model_index, price_index].max

            model_id = extract_model_id(cells[model_index])
            next unless model_id

            fields = extract_price_fields(cells[price_index])
            next unless fields

            fields = add_mode_prices(fields)
            fields = add_cache_read_prices(fields) if cache_models.include?(model_id)
            models[model_id] = fields
          end
        end

        def find_production_models_table(doc)
          heading = doc.css("h2, h3").find { |node| node["id"] == "production-models" } ||
                    doc.css("h2, h3").find { |node| node.text.strip == "Production Models" }
          return find_table_by_headers(doc) unless heading

          node = heading
          while (node = node.next_element)
            return node if node.name == "table"
            return node.at_css("table") if node.at_css("table")
            break if node.name.match?(/\Ah[23]\z/)
          end

          nil
        end

        def find_table_by_headers(doc)
          doc.css("table").find do |table|
            headers = header_texts(table)
            headers.include?("MODEL ID") && headers.include?("PRICE PER 1M TOKENS")
          end
        end

        def header_texts(table)
          table.css("thead th").map { |th| normalize_text(th.text) }
        end

        def column_index(headers, header)
          index = headers.find_index(header)
          raise Error, "Groq pricing column #{header.inspect} not found in #{headers.inspect}" unless index

          index
        end

        def extract_model_id(cell)
          explicit = cell.css("span").find { |node| node["class"].to_s.include?("font-mono") }&.text&.strip
          return explicit if model_id?(explicit)

          normalize_text(cell.text).scan(%r{[a-z0-9][a-z0-9_.-]*(?:/[a-z0-9][a-z0-9_.-]*)*}).reverse.find do |candidate|
            model_id?(candidate)
          end
        end

        def extract_price_fields(cell)
          text = normalize_text(cell.text)
          return nil if text.match?(/\bper hour\b|\bper 1M characters\b/i)

          input = parse_price(text, "input")
          output = parse_price(text, "output")
          { "input" => input, "output" => output }
        end

        def add_mode_prices(fields)
          fields.merge(
            "on_demand_input" => fields.fetch("input"),
            "on_demand_output" => fields.fetch("output"),
            "flex_input" => fields.fetch("input"),
            "flex_output" => fields.fetch("output")
          )
        end

        def add_cache_read_prices(fields)
          cache_read = (fields.fetch("input") * 0.5).round(6)
          fields.merge(
            "cache_read_input" => cache_read,
            "on_demand_cache_read_input" => cache_read,
            "flex_cache_read_input" => cache_read
          )
        end

        def extract_prompt_cache_models(doc)
          heading = doc.css("h2, h3").find { |node| normalize_text(node.text) == "Supported Models" }
          raise Error, "Groq prompt caching supported models section not found" unless heading

          html = []
          node = heading
          while (node = node.next_element)
            break if node.name.match?(/\Ah[23]\z/)

            html << node.to_html
          end

          models = Nokogiri::HTML.fragment(html.join).css("code").map { |code| code.text.strip }.select do |id|
            model_id?(id)
          end
          raise Error, "expected at least 2 prompt caching models, parsed #{models.size}" if models.size < 2

          models
        end

        def verify_prompt_cache_discount!(doc)
          return if normalize_text(doc.text).match?(/50% discount for cached input tokens/i)

          raise Error, "Groq prompt caching discount text not found"
        end

        def verify_flex_pricing!(doc)
          text = normalize_text(doc.text)
          return if text.match?(/same pricing as on-demand/i) || text.match?(/Pricing matches the on-demand tier/i)

          raise Error, "Groq flex on-demand pricing text not found"
        end

        def parse_price(text, label)
          match = text.match(/\$\s*(\d+(?:\.\d+)?)\s+#{Regexp.escape(label)}/i)
          raise Error, "unable to parse #{label} price #{text.inspect}" unless match

          Float(match[1])
        end

        def normalize_text(text)
          text.to_s.gsub(/\s+/, " ").strip
        end

        def model_id?(value)
          value.to_s.match?(%r{\A[a-z0-9][a-z0-9_.-]*(?:/[a-z0-9][a-z0-9_.-]*)*\z})
        end
      end
    end
  end
end
