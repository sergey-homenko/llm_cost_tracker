# frozen_string_literal: true

require "nokogiri"
require "time"

require_relative "../price_fields_validator"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Anthropic
        SOURCE_URL = "https://platform.claude.com/docs/en/about-claude/pricing"
        MIN_MODELS_EXPECTED = 10
        MAX_PRICE_PER_MTOK = 1000.0
        SERVICE_CHARGE_PATTERNS = {
          "web_search_request" => /Web search is available.*?\$\s*(\d+(?:\.\d+)?)\s+per 1,000 searches/i,
          "code_execution_hour" => /Additional usage beyond .*? billed at \$\s*(\d+(?:\.\d+)?)\s+per hour/i
        }.freeze
        FREE_SERVICE_CHARGE_PATTERNS = {
          "web_fetch_request" => /Web fetch usage has no additional charges/i
        }.freeze

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          base_table = find_table(doc, ["Base Input Tokens", "5m Cache Writes", "Cache Hits", "Output Tokens"])
          raise Error, "Anthropic base pricing table not found" unless base_table

          base = extract_base_pricing(base_table)
          batch = extract_batch_pricing(doc)
          deprecated = extract_deprecated_models(base_table)
          models = add_fast_mode_pricing(add_data_residency_pricing(merge(base, batch)))
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: deprecated,
            service_charges: extract_service_charges(doc)
          )
        end

        private

        def extract_service_charges(doc)
          text = doc.text.gsub(/\s+/, " ")
          charges = SERVICE_CHARGE_PATTERNS.to_h { |component, pattern| [component, text_price(text, pattern)] }
          FREE_SERVICE_CHARGE_PATTERNS.each do |component, pattern|
            charges[component] = 0.0 if text.match?(pattern)
          end
          charges
        end

        def text_price(text, pattern)
          match = text.match(pattern)
          raise Error, "Anthropic service charge price not found" unless match

          Float(match[1])
        end

        def extract_base_pricing(table)
          parse_table(table) do |cells, headers|
            {
              "input" => parse_price(cells[column_index(headers, "Base Input Tokens")]),
              "cache_write_input" => parse_price(cells[column_index(headers, "5m Cache Writes")]),
              "cache_write_extended_input" => parse_price(cells[column_index(headers, "1h Cache Writes")]),
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

        def add_data_residency_pricing(models)
          models.each_with_object({}) do |(model_id, fields), priced|
            priced[model_id] = if data_residency_model?(model_id)
                                 fields.merge(mode_prices(fields, "data_residency", 1.1))
                               else
                                 fields
                               end
          end
        end

        def add_fast_mode_pricing(models)
          fields = models["claude-opus-4-6"]
          return models unless fields

          models.merge(
            "claude-opus-4-6" => fields.merge(
              mode_prices(fields, "fast", 6.0, include_batch: false),
              mode_prices(fields, "fast_data_residency", 6.6, include_batch: false)
            )
          )
        end

        def mode_prices(fields, mode, multiplier, include_batch: true)
          fields.each_with_object({}) do |(field, value), prices|
            next unless mode_price_field?(field, include_batch: include_batch)

            prices["#{mode}_#{field}"] = (value * multiplier).round(6)
          end
        end

        def mode_price_field?(field, include_batch:)
          pattern = include_batch ? /\A(?:batch_)?/ : /\A/
          field.to_s.match?(
            /#{pattern.source}(?:input|output|cache_read_input|cache_write_input|cache_write_extended_input)\z/
          )
        end

        def data_residency_model?(model_id)
          match = model_id.match(/\Aclaude-(?:opus|sonnet|haiku)-(\d+)-(\d+)\z/)
          return false unless match

          major = match[1].to_i
          minor = match[2].to_i
          major > 4 || (major == 4 && minor >= 5)
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
          PriceFieldsValidator.call(
            models,
            minimum: MIN_MODELS_EXPECTED,
            maximum: MAX_PRICE_PER_MTOK,
            error_class: Error
          )
        end
      end
    end
  end
end
