# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"
require_relative "gemini/non_global_prices"
require_relative "gemini/price_table"
require_relative "gemini/pricing_page"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini < Base
        source_url "https://aistudio.google.com/docs/pricing.md"
        min_models 5
        max_price 1000.0
        anchors "gemini-2.5-pro", "gemini-2.5-flash"

        TIER_PREFIXES = { "Standard" => "", "Batch" => "batch_", "Flex" => "flex_", "Priority" => "priority_" }.freeze
        SCHEDULED_FROM = /starting (\w+ \d{1,2}, \d{4})/
        SCHEDULED_LINE = /#{SCHEDULED_FROM}\.?\z/
        CURRENT_LINE = /through \w+ \d{1,2}, \d{4}\.?\z/
        UNCAPTURED_MODEL = /(?<!transcribe)-live\b|-(?:streaming|native-audio)\b/
        VERTEX_URL = "https://cloud.google.com/model-garden/pricing"
        SOURCE_URLS = [source_url, VERTEX_URL].freeze

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          page = PricingPage.new(html.fetch(self.class.source_url))
          models = extract_models(page, Date.parse(scraped_at.to_s))
          validate!(models)
          models, notes = NonGlobalPrices.new(Nokogiri::HTML(html.fetch(VERTEX_URL))).call(models)
          Result.new(source_url:, scraped_at:, models:, deprecated_models: [], service_charges: {}, notes:)
        end

        private

        def extract_models(page, today)
          text_priced_as = {}
          models = priced_sections(page).each_with_object({}) do |(model_ids, section), collected|
            prices = section_prices(model_ids, section, today)
            model_ids.each do |model_id|
              collected[model_id] = prices.dup
              text_priced_as[model_id] = section.same_as if section.same_as && !prices.key?("output")
            end
          end
          add_text_output_prices(models, text_priced_as)
        end

        def priced_sections(page)
          page.sections.filter_map do |section|
            model_ids = section.model_ids.filter_map { |id| normalize_model_id(id) }
            [model_ids, section] if model_ids.any? && section.tabs.key?("Standard")
          end
        end

        def section_prices(model_ids, section, today)
          if section.tabs.size > 1 && !section.tabs.key?("Batch")
            raise Error, "Gemini batch pricing table not found for #{model_ids.first}"
          end

          dated_prices(section.tabs, section.notes, today)
        end

        def dated_prices(tabs, notes, today)
          starting = tabs.values.flat_map(&:values).join("\n")[SCHEDULED_FROM, 1]
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
          tabs.transform_values do |rows|
            rows.transform_values { |text| text.lines(chomp: true).grep_v(pattern).join("\n") }
          end
        end

        def tier_prices(tabs, notes)
          prices = TIER_PREFIXES.each_with_object({}) do |(heading, prefix), merged|
            merged.merge!(PriceTable.new(tabs[heading], notes).prices(prefix)) if tabs[heading]
          end
          prices.merge(PriceTable.new(tabs.fetch("Standard"), notes).service_prices)
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
