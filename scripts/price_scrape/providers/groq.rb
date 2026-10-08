# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"
require_relative "groq/models_page"
require_relative "groq/table"

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
        BATCH_SOURCE_URL = "https://console.groq.com/docs/batch"
        SPEECH_TO_TEXT_SOURCE_URL = "https://console.groq.com/docs/speech-to-text"
        SOURCE_URLS = [
          source_url,
          PROMPT_CACHING_SOURCE_URL,
          FLEX_PROCESSING_SOURCE_URL,
          DEPRECATIONS_SOURCE_URL,
          BATCH_SOURCE_URL,
          SPEECH_TO_TEXT_SOURCE_URL
        ].freeze
        MINIMUM_BILLED = /Minimum Billed Length(?:<[^>]*>|\s)*(\d+) seconds/
        PRICING_TERMS = {
          PROMPT_CACHING_SOURCE_URL => ["prompt caching discount", [/50% discount for cached input tokens/i]],
          FLEX_PROCESSING_SOURCE_URL => [
            "flex on-demand pricing", [/same pricing as on-demand|Pricing matches the on-demand tier/i]
          ],
          BATCH_SOURCE_URL => [
            "batch pricing", [
              /50% cost discount compared to synchronous API/i,
              /billed at the 50% batch rate regardless of cache status/i
            ]
          ]
        }.freeze
        MODEL_ID = %r{\A[a-z0-9][a-z0-9_.-]*(?:/[a-z0-9][a-z0-9_.-]*)*\z}
        SHUTDOWN_DATE_FORMAT = "%m/%d/%y"

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          pages = pages_from(html)
          docs = (SOURCE_URLS - [SPEECH_TO_TEXT_SOURCE_URL]).to_h { |url| [url, Nokogiri::HTML(pages.fetch(url))] }
          seconds = documented_factor(pages.fetch(SPEECH_TO_TEXT_SOURCE_URL), MINIMUM_BILLED, "minimum billed length")
          verify_pricing_terms!(docs)
          models = extract_models(docs, Pricing::Registry::MINIMUM_BILLED_SECONDS_KEY => seconds.to_i)
          validate!(models)
          deprecated = shutdown_models(docs.fetch(DEPRECATIONS_SOURCE_URL), scraped_at)
          Result.new(source_url:, scraped_at:, models:, deprecated_models: deprecated, service_charges: {})
        end

        private

        def pages_from(html)
          return html.transform_keys(&:to_s) if html.is_a?(Hash)

          self.class::SOURCE_URLS.to_h { |url| [url, html.to_s] }
        end

        def verify_pricing_terms!(docs)
          PRICING_TERMS.each do |url, (name, terms)|
            text = Table.text(docs.fetch(url).text)
            raise Error, "Groq #{name} text not found" unless terms.all? { |term| text.match?(term) }
          end
        end

        def extract_models(docs, minimum)
          cached = prompt_cache_models(docs.fetch(PROMPT_CACHING_SOURCE_URL))
          batched = batch_models(docs.fetch(BATCH_SOURCE_URL))
          ModelsPage.new(docs.fetch(self.class.source_url)).rows.transform_values do |row|
            next unit_prices(row[:units], minimum) unless row[:input]

            token_prices(row, cached: cached.include?(row[:id]), batched: batched.include?(row[:id]))
          end
        end

        def unit_prices(units, minimum) = units.merge(units.key?("transcription_minute") ? minimum : {})

        def token_prices(row, cached:, batched:)
          fields = add_mode_prices("input" => row[:input], "output" => row[:output])
          fields = add_cache_read_prices(fields) if cached
          batched ? fields : fields.reject { |field, _| field.start_with?("batch_") }
        end

        def add_mode_prices(fields)
          fields.merge(
            "on_demand_input" => fields.fetch("input"),
            "on_demand_output" => fields.fetch("output"),
            "flex_input" => fields.fetch("input"),
            "flex_output" => fields.fetch("output"),
            "batch_input" => (fields.fetch("input") * 0.5).round(6),
            "batch_output" => (fields.fetch("output") * 0.5).round(6)
          )
        end

        def add_cache_read_prices(fields)
          cache_read = (fields.fetch("input") * 0.5).round(6)
          fields.merge(
            "cache_read_input" => cache_read,
            "on_demand_cache_read_input" => cache_read,
            "flex_cache_read_input" => cache_read,
            "batch_cache_read_input" => fields.fetch("batch_input")
          )
        end

        def prompt_cache_models(doc)
          heading = doc.css("h2, h3").find { |node| Table.text(node.text) == "Supported Models" }
          raise Error, "Groq prompt caching supported models section not found" unless heading

          models = section_after(heading).css("code").map { |code| code.text.strip }.select { |id| model_id?(id) }
          raise Error, "expected at least 2 prompt caching models, parsed #{models.size}" if models.size < 2

          models
        end

        def section_after(heading)
          html = []
          node = heading
          html << node.to_html while (node = node.next_element) && !node.name.match?(/\Ah[23]\z/)
          Nokogiri::HTML.fragment(html.join)
        end

        def batch_models(doc)
          models = Table.all(doc).select { |table| table.header?("MODEL ID") }.flat_map do |table|
            index = table.column("MODEL ID")
            table.rows(index).map { |_row, cells| Table.text(cells[index].text) }
          end
          raise Error, "Groq batch model list not found" if models.none? { |id| model_id?(id) }

          models
        end

        def shutdown_models(doc, scraped_at)
          tables = Table.all(doc).select { |table| table.header?("SHUTDOWN DATE") }
          raise Error, "Groq deprecations table not found" if tables.empty?

          scraped_on = Date.parse(scraped_at)
          tables.flat_map { |table| shutdown_rows(table, scraped_on) }.uniq
        end

        def shutdown_rows(table, scraped_on)
          model = table.column("MODEL", excluding: "REPLACEMENT")
          shutdown = table.column("SHUTDOWN DATE")
          table.rows(model, shutdown).filter_map do |_row, cells|
            model_id = Table.text(cells[model].text)
            next unless model_id?(model_id)

            shutdown_on = shutdown_date(cells[shutdown])
            model_id if shutdown_on && shutdown_on <= scraped_on
          end
        end

        def shutdown_date(cell)
          Date.strptime(Table.text(cell.text), SHUTDOWN_DATE_FORMAT)
        rescue Date::Error
          nil
        end

        def model_id?(value) = value.to_s.match?(MODEL_ID)
      end
    end
  end
end
