# frozen_string_literal: true

require "nokogiri"
require "time"

module LlmCostTracker
  module PriceScrape
    module Providers
      class Anthropic
        SOURCE_URL = "https://platform.claude.com/docs/en/about-claude/pricing"
        MIN_MODELS_EXPECTED = 10
        MAX_PRICE_PER_MTOK = 1000.0

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          base_table = find_table(doc, ["Base Input Tokens", "5m Cache Writes", "Cache Hits", "Output Tokens"])
          raise Error, "Anthropic base pricing table not found" unless base_table

          base = extract_base_pricing(base_table)
          batch = extract_batch_pricing(doc)
          deprecated = extract_deprecated_models(base_table)
          models = merge(base, batch)
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: deprecated
          )
        end

        private

        def extract_base_pricing(table)
          parse_table(table) do |cells, headers|
            {
              "input" => parse_price(cells[column_index(headers, "Base Input Tokens")]),
              "cache_write_input" => parse_price(cells[column_index(headers, "5m Cache Writes")]),
              "cache_read_input" => parse_price(cells[column_index(headers, "Cache Hits")]),
              "output" => parse_price(cells[column_index(headers, "Output Tokens")])
            }
          end
        end

        def extract_deprecated_models(table)
          table.css("tbody tr").each_with_object([]) do |tr, acc|
            first_cell = tr.css("td").first
            next unless first_cell
            next if first_cell.css("a[href*='model-deprecations']").empty?

            model_id = normalize_model_id(first_cell.text)
            acc << model_id if model_id
          end
        end

        def extract_batch_pricing(doc)
          table = find_table(doc, ["Batch input", "Batch output"])
          return {} unless table

          parse_table(table) do |cells, headers|
            {
              "batch_input" => parse_price(cells[column_index(headers, "Batch input")]),
              "batch_output" => parse_price(cells[column_index(headers, "Batch output")])
            }
          end
        end

        def find_table(doc, required_header_substrings)
          doc.css("table").find do |table|
            headers = header_texts(table)
            required_header_substrings.all? { |sub| headers.any? { |h| h.include?(sub) } }
          end
        end

        def parse_table(table)
          headers = header_texts(table)
          model_index = column_index(headers, "Model")
          table.css("tbody tr").each_with_object({}) do |tr, acc|
            cells = tr.css("td").map { |td| td.text.strip }
            next if cells.size < headers.size

            model_id = normalize_model_id(cells[model_index])
            next unless model_id

            acc[model_id] = yield(cells, headers)
          end
        end

        def header_texts(table)
          table.css("thead th").map { |th| th.text.strip }
        end

        def column_index(headers, substring)
          index = headers.find_index { |h| h.include?(substring) }
          raise Error, "column matching #{substring.inspect} not found in #{headers.inspect}" unless index

          index
        end

        def merge(base_pricing, batch_pricing)
          base_pricing.each_with_object({}) do |(model_id, fields), result|
            result[model_id] = fields.merge(batch_pricing.fetch(model_id, {}))
          end
        end

        def normalize_model_id(display_name)
          cleaned = display_name.to_s.gsub(/\s*\(.*?\)\s*\z/, "").strip
          match = cleaned.match(/\AClaude (Opus|Sonnet|Haiku) (\d+(?:\.\d+)?)\z/)
          return nil unless match

          family = match[1].downcase
          version = match[2].tr(".", "-")
          "claude-#{family}-#{version}"
        end

        def parse_price(text)
          match = text.to_s.match(%r{\$\s*(\d+(?:\.\d+)?)\s*/\s*MTok}i)
          raise Error, "unable to parse price #{text.inspect}" unless match

          Float(match[1])
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
