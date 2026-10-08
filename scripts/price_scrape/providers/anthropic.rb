# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"
require_relative "gemini"
require_relative "anthropic/price_table"
require_relative "anthropic/vertex_long_context"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Anthropic < Base
        source_url "https://platform.claude.com/docs/en/about-claude/pricing"
        min_models 10
        max_price 1000.0
        anchors "claude-fable-5", "claude-opus-4-7", "claude-sonnet-4-6"

        SOURCE_URLS = [source_url, Gemini::VERTEX_URL].freeze
        DATA_RESIDENCY_MULTIPLIER = 1.1
        BATCH_MULTIPLIER = 0.5
        BASE_TABLE = ["Base tokens Input", "5m writes", "Hits", "Base tokens Output"].freeze
        BASE_COLUMNS = {
          "input" => "Base tokens Input", "cache_write_input" => "5m writes",
          "cache_write_extended_input" => "1h writes", "cache_read_input" => "Hits", "output" => "Base tokens Output"
        }.freeze
        BATCH_COLUMNS = { "batch_input" => "Batch tokens Input", "batch_output" => "Batch tokens Output" }.freeze
        FAST_TABLE = %w[Model Input Output].freeze
        PRICE_DIMENSION = "(?:input|output|cache_read_input|cache_write_input|cache_write_extended_input)"
        PRICE_FIELD = /\A(?:above_context_)?(?:batch_)?#{PRICE_DIMENSION}\z/
        SYNCHRONOUS_PRICE_FIELD = /\A(?:above_context_)?#{PRICE_DIMENSION}\z/

        SERVICE_CHARGE_PATTERNS = {
          "web_search_request" => /Web search is available.*?\$\s*(\d+(?:\.\d+)?)\s+per 1,000 searches/i,
          "code_execution_hour" => /Additional usage beyond .*? billed at \$\s*(\d+(?:\.\d+)?)(?:\s+USD)?\s+per hour/i
        }.freeze
        FREE_SERVICE_CHARGE_PATTERNS = {
          "web_fetch_request" => /Web fetch usage has no additional charges/i
        }.freeze
        REGIONAL_PREMIUM_NOTE = /10% premium over global endpoints.*?Haiku 4\.5, Opus 4\.5, and all future models/i
        EFFECTIVE_DATE_QUALIFIER =
          /\A(?<name>.+?)\s*(?<boundary>through|starting)\s+(?<date>[A-Z][a-z]+ \d{1,2}, \d{4})\z/
        RETIRED_NOTE = /"name":"([^"]+)","note":\{"kind":"lifecycle","label":"Retired","explanation":"([^"]*)"/
        PARTNER_SERVED = /\Aretired(, except on [A-Z][\w ]+)?\.\z/

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          @effective_on = Date.parse(scraped_at)
          doc = Nokogiri::HTML(html.fetch(self.class.source_url))
          base, deprecated_models = base_table_models(doc)
          models = with_mode_prices(with_long_context(base, html), doc)
          validate!(models)
          verify_regional_premium!(doc)
          Result.new(source_url:, scraped_at:, models:, deprecated_models:, service_charges: service_charges(doc))
        end

        private

        def base_table_models(doc)
          table = find_table(doc) { |candidate| candidate.headers?(BASE_TABLE) }
          raise Error, "Anthropic base pricing table not found" unless table

          base = table.prices(BASE_COLUMNS)
          verify_batch_discount!(doc, base)
          [base, retired_models(table, doc)]
        end

        def find_table(doc, &) = PriceTable.find(doc, method(:normalize_model_id), &)

        def verify_batch_discount!(doc, base)
          derived = add_batch_pricing(base)
          batch_prices(doc).each do |model_id, scraped|
            expected = derived[model_id]&.slice(*scraped.keys)
            next if expected.nil? || expected == scraped

            message = "Anthropic batch pricing for #{model_id} is no longer #{BATCH_MULTIPLIER} of base " \
                      "(#{scraped} vs #{expected})"
            raise Error, message
          end
        end

        def batch_prices(doc)
          table = find_table(doc) { |candidate| candidate.headers?(BATCH_COLUMNS.values) }
          table ? table.prices(BATCH_COLUMNS) : {}
        end

        def retired_models(table, doc)
          notes = doc.text.delete("\\").scan(RETIRED_NOTE).to_h
          table.retired_names.filter_map do |name|
            note = notes.fetch(name) { raise Error, "Anthropic retired row #{name.inspect} has no lifecycle note" }
            match = note.match(PARTNER_SERVED)
            raise Error, "Anthropic lifecycle note for #{name} not understood: #{note.inspect}" unless match

            normalize_model_id(name) unless match[1]
          end
        end

        def with_long_context(models, html)
          vertex = Nokogiri::HTML(html.fetch(Gemini::VERTEX_URL))
          VertexLongContext.new(vertex, method(:normalize_model_id)).call(models)
        end

        def with_mode_prices(models, doc)
          add_fast_mode_pricing(add_data_residency_pricing(add_batch_pricing(models)), doc)
        end

        def add_batch_pricing(models)
          models.transform_values do |fields|
            standard = fields.slice("input", "output", "above_context_input", "above_context_output")
            fields.merge(mode_prices(standard, "batch", BATCH_MULTIPLIER))
          end
        end

        def add_data_residency_pricing(models)
          models.to_h do |model_id, fields|
            next [model_id, fields] unless data_residency_model?(model_id)

            [model_id, fields.merge(mode_prices(fields, "data_residency", DATA_RESIDENCY_MULTIPLIER))]
          end
        end

        def add_fast_mode_pricing(models, doc)
          table = find_table(doc) { |candidate| FAST_TABLE.all? { |header| candidate.headers.include?(header) } }
          raise Error, "Anthropic fast mode pricing table not found" unless table

          fast = table.fast_prices
          models.to_h do |model_id, base|
            multiplier = fast_mode_multiplier(base, fast[model_id], model_id)
            [model_id, multiplier ? base.merge(fast_mode_prices(base, multiplier, model_id)) : base]
          end
        end

        def fast_mode_multiplier(base, fast_row, model_id)
          return nil unless fast_row

          base_input = base["input"]
          raise Error, "Anthropic fast mode for #{model_id} has no base input price" unless base_input&.positive?

          multiplier = fast_row.fetch("input") / base_input
          unless (base.fetch("output") * multiplier).round(6) == fast_row.fetch("output")
            raise Error, "Anthropic fast mode input and output multipliers diverge for #{model_id}"
          end

          multiplier
        end

        def fast_mode_prices(base, multiplier, model_id)
          prices = mode_prices(base, "fast", multiplier, SYNCHRONOUS_PRICE_FIELD)
          return prices unless data_residency_model?(model_id)

          residency = (multiplier * DATA_RESIDENCY_MULTIPLIER).round(6)
          prices.merge(mode_prices(base, "fast_data_residency", residency, SYNCHRONOUS_PRICE_FIELD))
        end

        def mode_prices(fields, mode, multiplier, priced = PRICE_FIELD)
          fields.each_with_object({}) do |(field, value), prices|
            next unless field.to_s.match?(priced)

            prices[field.sub(/\A(above_context_)?/, "\\1#{mode}_")] = (value * multiplier).round(6)
          end
        end

        def data_residency_model?(model_id)
          match = model_id.match(/\Aclaude-[a-z]+-(\d+)(?:-(\d+))?\z/)
          return false unless match

          major = match[1].to_i
          minor = match[2].to_i
          major > 4 || (major == 4 && minor >= 5)
        end

        def verify_regional_premium!(doc)
          return if page_text(doc).match?(REGIONAL_PREMIUM_NOTE)

          raise Error, "Anthropic regional endpoint premium note not found"
        end

        def service_charges(doc)
          text = page_text(doc)
          charges = SERVICE_CHARGE_PATTERNS.transform_values { |pattern| text_price(text, pattern) }
          FREE_SERVICE_CHARGE_PATTERNS.each { |component, pattern| charges[component] = 0.0 if text.match?(pattern) }
          charges
        end

        def page_text(doc) = doc.text.gsub(/\s+/, " ")

        def text_price(text, pattern)
          match = text.match(pattern)
          raise Error, "Anthropic service charge price not found" unless match

          Float(match[1])
        end

        def normalize_model_id(display_name)
          cleaned = display_name.to_s.gsub(/\s*\(.*?\)\s*\z/, "").strip
          if (scoped = cleaned.match(EFFECTIVE_DATE_QUALIFIER))
            return nil unless effective?(scoped[:boundary], Date.parse(scoped[:date]))

            cleaned = scoped[:name]
          end
          match = cleaned.match(/\AClaude ([A-Z][a-z]+) (\d+(?:\.\d+)?)\z/)
          raise Error, "no model ID for Anthropic price row #{display_name.inspect}" unless match

          family = match[1].downcase
          version = match[2].tr(".", "-")
          match[2].to_i < 4 ? "claude-#{version}-#{family}" : "claude-#{family}-#{version}"
        end

        def effective?(boundary, date)
          boundary == "through" ? @effective_on <= date : @effective_on >= date
        end
      end
    end
  end
end
