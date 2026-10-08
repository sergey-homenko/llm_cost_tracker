# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"
require_relative "gemini/non_global_prices"
require_relative "gemini/price_table"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini < Base
        source_url "https://ai.google.dev/gemini-api/docs/pricing"
        min_models 5
        max_price 1000.0
        anchors "gemini-2.5-pro", "gemini-2.5-flash"

        TIER_PREFIXES = { "Standard" => "", "Batch" => "batch_", "Flex" => "flex_", "Priority" => "priority_" }.freeze
        SCHEDULED_FROM = /starting (\w+ \d{1,2}, \d{4})/
        SCHEDULED_LINE = /#{SCHEDULED_FROM}\.?\z/
        CURRENT_LINE = /through \w+ \d{1,2}, \d{4}\.?\z/
        TEXT_PRICED_AS = /Text input and output\s+is priced the same as/
        UNCAPTURED_MODEL = /(?<!transcribe)-live\b|-(?:streaming|native-audio)\b/
        VERTEX_URL = "https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing"
        SOURCE_URLS = [source_url, VERTEX_URL].freeze

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.fetch(self.class.source_url))
          models = extract_models(doc, Date.parse(scraped_at.to_s))
          validate!(models)
          models, notes = NonGlobalPrices.new(Nokogiri::HTML(html.fetch(VERTEX_URL))).call(models)
          Result.new(source_url:, scraped_at:, models:, deprecated_models: [], service_charges: {}, notes:)
        end

        private

        def extract_models(doc, today)
          article = doc.at_css("div.devsite-article-body")
          raise Error, "Gemini pricing article body not found" unless article

          text_priced_as = {}
          models = priced_sections(article).each_with_object({}) do |(model_ids, tabs, same_as), collected|
            prices = section_prices(model_ids, tabs, today)
            model_ids.each do |model_id|
              collected[model_id] = prices.dup
              text_priced_as[model_id] = same_as if same_as && !prices.key?("output")
            end
          end
          add_text_output_prices(models, text_priced_as)
        end

        def priced_sections(article)
          sections(article).select { |model_ids, tabs, _| !model_ids.empty? && find_table(tabs, "Standard") }
        end

        def sections(article)
          model_ids = []
          same_as = nil
          article.children.reject(&:text?).each_with_object([]) do |child, sections|
            if models_section?(child)
              model_ids = section_model_ids(child)
            elsif pricing_tabs?(child)
              sections << [model_ids, child, same_as]
              model_ids = []
              same_as = nil
            elsif child.text.match?(TEXT_PRICED_AS)
              same_as = child.at_css("a[href^='#']")&.[]("href").to_s.delete_prefix("#")
            end
          end
        end

        def models_section?(node) = node["class"]&.include?("models-section")

        def section_model_ids(section)
          section.css("div.heading-group code").filter_map { |code| normalize_model_id(code.text.strip) }
        end

        def pricing_tabs?(node)
          node.name == "table" ||
            node["class"]&.include?("ds-selector-tabs") ||
            node.at_css("devsite-selector[data-ds-scope='code-sample']") ||
            (node["data-ds-scope"] == "code-sample")
        end

        def section_prices(model_ids, tabs, today)
          if tabs.css("section").size > 1 && !find_table(tabs, "Batch")
            raise Error, "Gemini batch pricing table not found for #{model_ids.first}"
          end

          dated_prices(tabs, footnotes(tabs), today)
        end

        def dated_prices(tabs, notes, today)
          starting = tabs.text[SCHEDULED_FROM, 1]
          return tier_prices(tabs, notes) unless starting

          from = Date.parse(starting)
          scheduled = tier_prices(without_lines(tabs, CURRENT_LINE), notes)
          return scheduled if from <= today

          current = tier_prices(without_lines(tabs, SCHEDULED_LINE), notes)
          scheduled.each_with_object(current) do |(key, price), prices|
            prices["#{key}_from_#{from.iso8601}"] = price unless current[key] == price
          end
        end

        def without_lines(tabs, pattern)
          tabs.dup.tap do |copy|
            copy.css("td").each do |cell|
              lines = cell.inner_html.split(%r{<br\s*/?>}i)
              kept = lines.reject { |line| Nokogiri::HTML.fragment(line).text.strip.match?(pattern) }
              cell.inner_html = kept.join("<br>")
            end
          end
        end

        def tier_prices(tabs, notes)
          prices = TIER_PREFIXES.each_with_object({}) do |(heading, prefix), merged|
            table = find_table(tabs, heading)
            merged.merge!(PriceTable.new(table, notes).prices(prefix)) if table
          end
          prices.merge(PriceTable.new(find_table(tabs, "Standard"), notes).service_prices)
        end

        def find_table(tabs, heading)
          return (tabs if heading == "Standard") if tabs.name == "table"

          tabs.css("section").find { |sec| sec.at_css("h3")&.text&.strip == heading }&.at_css("table")
        end

        def footnotes(tabs)
          tabs.xpath("following-sibling::*").take_while { |node| !models_section?(node) }.map(&:text).join
        end

        def add_text_output_prices(models, text_priced_as)
          text_priced_as.each do |model_id, source_id|
            source = models.fetch(source_id) do
              raise Error, "Gemini #{model_id} text is priced as #{source_id.inspect}, which the page does not price"
            end
            TIER_PREFIXES.each_value do |prefix|
              next unless models[model_id].key?("#{prefix}input")

              models[model_id]["#{prefix}output"] = source.fetch("#{prefix}output") do
                raise Error, "Gemini #{source_id} has no #{prefix}output rate for #{model_id}"
              end
            end
          end
          models
        end

        def normalize_model_id(id)
          id if id.start_with?("gemini-") && !id.match?(UNCAPTURED_MODEL)
        end
      end
    end
  end
end
