# frozen_string_literal: true

require "nokogiri"
require "time"

require_relative "../price_fields_validator"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini
        SOURCE_URL = "https://ai.google.dev/gemini-api/docs/pricing"
        MIN_MODELS_EXPECTED = 5
        MAX_PRICE_PER_MTOK = 1000.0
        ANCHOR_MODELS = %w[gemini-2.5-pro gemini-2.5-flash].freeze

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = extract_models(doc)
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
            service_charges: {}
          )
        end

        private

        def extract_models(doc)
          article = doc.at_css("div.devsite-article-body")
          raise Error, "Gemini pricing article body not found" unless article

          pair_sections(article).each_with_object({}) do |(model_id, tabs), models|
            next unless model_id

            standard_table = find_standard_table(tabs)
            next unless standard_table

            batch_table = find_batch_table(tabs)
            raise Error, "Gemini batch pricing table not found for #{model_id}" unless batch_table

            models[model_id] = extract_text_pricing(standard_table)
            models[model_id] = models.fetch(model_id).merge(extract_batch_pricing(batch_table))
            models[model_id] = models.fetch(model_id).merge(extract_flex_pricing(tabs))
            models[model_id] = models.fetch(model_id).merge(extract_priority_pricing(tabs))
          end
        end

        def pair_sections(article)
          current_model_id = nil
          article.children.each_with_object([]) do |child, pairs|
            next if child.text?
            next unless child.respond_to?(:css)

            if child["class"]&.include?("models-section")
              raw_id = child.at_css("div.heading-group code")&.text&.strip
              current_model_id = normalize_model_id(raw_id)
            elsif pricing_tabs_container?(child)
              pairs << [current_model_id, child]
              current_model_id = nil
            end
          end
        end

        def pricing_tabs_container?(child)
          child["class"]&.include?("ds-selector-tabs") ||
            child.at_css("devsite-selector[data-ds-scope='code-sample']") ||
            (child["data-ds-scope"] == "code-sample")
        end

        def find_standard_table(tabs)
          find_table(tabs, "Standard")
        end

        def find_batch_table(tabs)
          find_table(tabs, "Batch")
        end

        def find_table(tabs, heading)
          tabs.css("section").find { |sec| sec.at_css("h3")&.text&.strip == heading }&.at_css("table")
        end

        def extract_text_pricing(table)
          extract_pricing(table, input: "input", output: "output", cache_read_input: "cache_read_input")
        end

        def extract_batch_pricing(table)
          extract_pricing(table, input: "batch_input", output: "batch_output",
                          cache_read_input: "batch_cache_read_input")
        end

        def extract_flex_pricing(tabs)
          table = find_table(tabs, "Flex")
          return {} unless table

          extract_pricing(table, input: "flex_input", output: "flex_output",
                          cache_read_input: "flex_cache_read_input")
        end

        def extract_priority_pricing(tabs)
          table = find_table(tabs, "Priority")
          return {} unless table

          extract_pricing(table, input: "priority_input", output: "priority_output",
                          cache_read_input: "priority_cache_read_input")
        end

        def extract_pricing(table, input:, output:, cache_read_input:)
          rows = parse_table(table)
          input_key = rows.keys.find { |k| k.start_with?("Input price") }
          output_key = rows.keys.find { |k| k.start_with?("Output price") }
          raise Error, "Gemini text pricing rows not found" unless input_key && output_key

          prices = token_prices(rows, input_key: input_key, output_key: output_key, input: input, output: output)
          add_context_tier_prices(prices, rows, input_key: input_key, output_key: output_key, input: input,
                                  output: output)
          add_cache_read_prices(prices, rows, cache_read_input: cache_read_input)
          prices
        end

        def token_prices(rows, input_key:, output_key:, input:, output:)
          prices = {
            input => parse_price(rows[input_key]),
            output => parse_price(rows[output_key])
          }
          audio_input = parse_modality_price(rows[input_key], "audio")
          prices[audio_price_key(input)] = audio_input if audio_input
          audio_output = parse_modality_price(rows[output_key], "audio")
          prices[audio_price_key(output)] = audio_output if audio_output
          prices
        end

        def add_context_tier_prices(prices, rows, input_key:, output_key:, input:, output:)
          input_tiers = parse_prompt_tier_prices(rows[input_key])
          output_tiers = parse_prompt_tier_prices(rows[output_key])
          return unless input_tiers && output_tiers

          prices["_context_price_threshold_tokens"] = 200_000
          prices["above_context_#{input}"] = input_tiers.fetch(1)
          prices["above_context_#{output}"] = output_tiers.fetch(1)
        end

        def add_cache_read_prices(prices, rows, cache_read_input:)
          context_cache_key = rows.keys.find { |k| k.start_with?("Context caching price") }
          return unless context_cache_key && rows[context_cache_key].match?(/\$\s*\d/)

          prices[cache_read_input] = parse_price(rows[context_cache_key])
          context_cache_tiers = parse_prompt_tier_prices(rows[context_cache_key])
          prices["above_context_#{cache_read_input}"] = context_cache_tiers.fetch(1) if context_cache_tiers
        end

        def parse_table(table)
          table.css("tbody tr").each_with_object({}) do |tr, acc|
            cells = tr.css("td").map { |td| cell_text(td) }
            next if cells.size < 3

            acc[cells[0]] = cells[2]
          end
        end

        def normalize_model_id(raw_id)
          id = raw_id.to_s.split(/\s+and\s+|\s*,\s*/).first&.strip.to_s
          return nil unless id.match?(/\Agemini-/)
          return nil if id.include?("-preview")
          return nil if id.match?(/-(?:tts|image|embedding|live|robotics|computer|native-audio)/)
          return nil unless id.match?(/\Agemini-\d+(?:\.\d+)?-(?:pro|flash(?:-lite)?)/)

          id
        end

        def audio_price_key(field)
          field.sub(/(?:input|output)\z/) { |direction| "audio_#{direction}" }
        end

        def cell_text(cell)
          html = cell.inner_html.gsub(%r{<br\s*/?>}i, "\n")
          Nokogiri::HTML.fragment(html).text.strip
        end

        def parse_price(text)
          match = text.to_s.match(/\$\s*(\d+(?:\.\d+)?)/)
          raise Error, "unable to parse price #{text.inspect}" unless match

          Float(match[1])
        end

        def parse_modality_price(text, modality)
          pattern = /\([^)]*\b#{Regexp.escape(modality)}\b[^)]*\)/i
          line = text.lines.find { |candidate| candidate.match?(pattern) }
          return nil unless line

          parse_price(line)
        end

        def parse_prompt_tier_prices(text)
          return nil unless text.to_s.match?(/prompts?\s*>/i)

          prices = text.to_s.scan(/\$\s*(\d+(?:\.\d+)?)/).flatten.map { |price| Float(price) }
          prices.size >= 2 ? prices.first(2) : nil
        end
      end
    end
  end
end
