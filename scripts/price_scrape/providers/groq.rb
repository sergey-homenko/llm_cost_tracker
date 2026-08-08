# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Groq < Base
        source_url "https://console.groq.com/docs/models"
        min_models 4
        max_price 1000.0
        anchors "openai/gpt-oss-20b", "openai/gpt-oss-120b"

        PROMPT_CACHING_SOURCE_URL = "https://console.groq.com/docs/prompt-caching"
        FLEX_PROCESSING_SOURCE_URL = "https://console.groq.com/docs/flex-processing"
        DEPRECATIONS_SOURCE_URL = "https://console.groq.com/docs/deprecations"
        SOURCE_URLS = [
          source_url,
          PROMPT_CACHING_SOURCE_URL,
          FLEX_PROCESSING_SOURCE_URL,
          DEPRECATIONS_SOURCE_URL
        ].freeze

        MODEL_CARD_PATH = "/docs/model/"
        SHUTDOWN_DATE_FORMAT = "%m/%d/%y"

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          pages = pages_from(html)
          pricing_doc = Nokogiri::HTML(pages.fetch(self.class.source_url))
          prompt_caching_doc = Nokogiri::HTML(pages.fetch(PROMPT_CACHING_SOURCE_URL))
          flex_doc = Nokogiri::HTML(pages.fetch(FLEX_PROCESSING_SOURCE_URL))
          deprecations_doc = Nokogiri::HTML(pages.fetch(DEPRECATIONS_SOURCE_URL))

          verify_prompt_cache_discount!(prompt_caching_doc)
          verify_flex_pricing!(flex_doc)

          cache_models = extract_prompt_cache_models(prompt_caching_doc)
          models = extract_models(pricing_doc, cache_models: cache_models)
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: extract_shutdown_models(deprecations_doc, scraped_at: scraped_at),
            service_charges: {}
          )
        end

        private

        def pages_from(html)
          return html.transform_keys(&:to_s) if html.is_a?(Hash)

          self.class::SOURCE_URLS.to_h { |url| [url, html.to_s] }
        end

        def extract_models(doc, cache_models:)
          tables = find_text_models_tables(doc)
          raise Error, "Groq token models pricing table not found" if tables.empty?

          rows = tables.flat_map { |table| token_rows(table) }

          resolve_rows(rows).transform_values do |row|
            fields = add_mode_prices("input" => row[:input], "output" => row[:output])
            cache_models.include?(row[:id]) ? add_cache_read_prices(fields) : fields
          end
        end

        def token_rows(table)
          headers = header_texts(table)
          model_index = column_index(headers, "MODEL ID")
          price_index = column_index(headers, "PRICE PER")
          last_index = [model_index, price_index].max

          table.css("tbody tr").filter_map do |row|
            cells = row.css("td")
            next if cells.size <= last_index

            model_id = model_card_id(row)
            next unless model_id

            input, output = token_prices(cells[price_index])
            next unless input && output

            { id: model_id, name: normalize_text(cells[model_index].text), input: input, output: output }
          end
        end

        def find_text_models_tables(doc)
          doc.css("table").select do |table|
            headers = header_texts(table)
            header?(headers, "MODEL ID") && header?(headers, "PRICE PER")
          end
        end

        def header_texts(table)
          table.css("thead th").map { |th| normalize_text(th.text) }
        end

        def header?(headers, needle)
          headers.any? { |header| header.upcase.include?(needle) }
        end

        def column_index(headers, needle, excluding: nil)
          index = headers.find_index do |header|
            upcased = header.upcase
            upcased.include?(needle) && !(excluding && upcased.include?(excluding))
          end
          raise Error, "Groq pricing column #{needle.inspect} not found in #{headers.inspect}" unless index

          index
        end

        def model_card_id(row)
          href = row.css("a").filter_map { |node| node["href"] }.find { |link| link.include?(MODEL_CARD_PATH) }
          return nil unless href

          id = href.split(MODEL_CARD_PATH, 2).last.to_s.split(/[?#]/).first
          id if model_id?(id)
        end

        def token_prices(cell)
          text = normalize_text(cell.text)
          [labeled_price(text, "input"), labeled_price(text, "output")]
        end

        def labeled_price(text, label)
          match = text.match(/\$\s*(\d+(?:\.\d+)?)\s*#{label}\b/i)
          return nil unless match

          Float(match[1])
        end

        def resolve_rows(rows)
          rows.group_by { |row| row[:id] }.each_with_object({}) do |(id, group), resolved|
            resolved[id] = group.size == 1 ? group.first : disambiguate(id, group)
          end
        end

        def disambiguate(id, group)
          signature = squash(id.split("/").last)
          consistent = group.select { |row| squash(row[:name]).include?(signature) }
          unless consistent.size == 1
            names = group.map { |row| row[:name] }
            raise Error, "Groq pricing ambiguous model id #{id.inspect} across #{names.inspect}"
          end

          consistent.first
        end

        def squash(value)
          value.to_s.downcase.gsub(/[^a-z0-9]/, "")
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

        def extract_shutdown_models(doc, scraped_at:)
          tables = doc.css("table").select { |table| header?(header_texts(table), "SHUTDOWN DATE") }
          raise Error, "Groq deprecations table not found" if tables.empty?

          scraped_on = Date.parse(scraped_at)
          tables.flat_map { |table| shutdown_rows(table, scraped_on: scraped_on) }.uniq
        end

        def shutdown_rows(table, scraped_on:)
          headers = header_texts(table)
          model_index = column_index(headers, "MODEL", excluding: "REPLACEMENT")
          shutdown_index = column_index(headers, "SHUTDOWN DATE")
          last_index = [model_index, shutdown_index].max

          table.css("tbody tr").filter_map do |row|
            cells = row.css("td")
            next if cells.size <= last_index

            model_id = normalize_text(cells[model_index].text)
            next unless model_id?(model_id)

            shutdown_on = shutdown_date(cells[shutdown_index])
            model_id if shutdown_on && shutdown_on <= scraped_on
          end
        end

        def shutdown_date(cell)
          Date.strptime(normalize_text(cell.text), SHUTDOWN_DATE_FORMAT)
        rescue Date::Error
          nil
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
