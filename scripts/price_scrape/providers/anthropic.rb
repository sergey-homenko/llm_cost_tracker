# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"
require_relative "gemini"

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
        PROMPT_TIER = /for prompts (up to|over) ([\d,]+) tokens/
        VERTEX_LONG_CONTEXT_ROWS = {
          "Input" => "input", "Output" => "output", "5m Cache Write" => "cache_write_input",
          "1h Cache Write" => "cache_write_extended_input", "Cache Hit" => "cache_read_input"
        }.freeze

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          @effective_on = Date.parse(scraped_at)
          doc = Nokogiri::HTML(html.fetch(self.class.source_url))
          base_table = find_table(doc, ["Base tokens Input", "5m writes", "Hits", "Base tokens Output"])
          raise Error, "Anthropic base pricing table not found" unless base_table

          base = extract_base_pricing(base_table)
          verify_batch_discount!(doc, base)
          deprecated = extract_deprecated_models(base_table, doc.text.delete("\\").scan(RETIRED_NOTE).to_h)
          base = add_vertex_long_context(base, Nokogiri::HTML(html.fetch(Gemini::VERTEX_URL)))
          models = add_fast_mode_pricing(add_data_residency_pricing(add_batch_pricing(base)), doc)
          validate!(models)
          text = doc.text.gsub(/\s+/, " ")
          raise Error, "Anthropic regional endpoint premium note not found" unless text.match?(REGIONAL_PREMIUM_NOTE)

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
              "input" => parse_price(cells[column_index(headers, "Base tokens Input")]),
              "cache_write_input" => parse_price(cells[column_index(headers, "5m writes")]),
              "cache_write_extended_input" => parse_price(cells[column_index(headers, "1h writes")]),
              "cache_read_input" => parse_price(cells[column_index(headers, "Hits")]),
              "output" => parse_price(cells[column_index(headers, "Base tokens Output")])
            }
          end
        end

        def extract_deprecated_models(table, notes)
          table.css("tbody tr").filter_map do |tr|
            name = model_name(tr.at_css("td")) if tr.at_css("td [aria-label*='(Retired)']")
            next unless name

            note = notes.fetch(name) { raise Error, "Anthropic retired row #{name.inspect} has no lifecycle note" }
            match = note.match(PARTNER_SERVED)
            raise Error, "Anthropic lifecycle note for #{name} not understood: #{note.inspect}" unless match

            normalize_model_id(name) unless match[1]
          end
        end

        def extract_batch_pricing(doc)
          table = find_table(doc, ["Batch tokens Input", "Batch tokens Output"])
          return {} unless table

          parse_table(table) do |cells, headers|
            {
              "batch_input" => parse_price(cells[column_index(headers, "Batch tokens Input")]),
              "batch_output" => parse_price(cells[column_index(headers, "Batch tokens Output")])
            }
          end
        end

        def verify_batch_discount!(doc, base)
          derived = add_batch_pricing(base)
          extract_batch_pricing(doc).each do |model_id, scraped|
            expected = derived[model_id]&.slice(*scraped.keys)
            next if expected.nil? || expected == scraped

            message = "Anthropic batch pricing for #{model_id} is no longer #{BATCH_MULTIPLIER} of base " \
                      "(#{scraped} vs #{expected})"
            raise Error, message
          end
        end

        def add_vertex_long_context(models, vertex)
          vertex_long_context_rows(vertex).each_with_object(models.dup) do |(name, rows), priced|
            next if rows.none? { |_field, (base, long)| long && long != base }

            model_id = normalize_model_id(name.sub(/\A(?!Claude )/, "Claude "))
            next unless models.key?(model_id) && !models[model_id].key?(Pricing::Registry::CONTEXT_THRESHOLD_KEY)
            unless rows.size == VERTEX_LONG_CONTEXT_ROWS.size &&
                   rows.all? { |field, (base, long)| long && base == models[model_id][field] }
              raise Error, "Vertex AI long-context prices for #{name} do not extend Anthropic's: #{rows}"
            end

            priced[model_id] = models[model_id].merge(
              rows.to_h { |field, (_base, long)| ["above_context_#{field}", long] },
              Pricing::Registry::CONTEXT_THRESHOLD_KEY => 200_000
            )
          end
        end

        def vertex_long_context_rows(vertex)
          table = vertex_global_claude_table(vertex)
          columns = vertex_long_context_columns(table.at_css("tr").css("th").map { |th| th.text.strip })
          model = nil
          table.css("tr").each_with_object({}) do |tr, rows|
            cells = tr.css("td").map { |td| td.text.gsub(/\s+/, " ").strip }
            next if cells.empty?

            model = cells[0] unless cells[0].empty?
            field = VERTEX_LONG_CONTEXT_ROWS[cells[1]]
            (rows[model] ||= {})[field] = cells.values_at(*columns).map { |cell| cell[/\$([\d.]+)/, 1]&.to_f } if field
          end
        end

        def vertex_long_context_columns(headers)
          [/(?:=<|<=|≤)\s*200K input tokens/, />\s*200K input tokens/].map do |label|
            headers.find_index { |header| header.match?(label) } or
              raise Error, "Vertex AI Claude long-context columns not found in #{headers.inspect}"
          end
        end

        def vertex_global_claude_table(vertex)
          tab = vertex.css("#anthropics-claude-models [role=tab]").find { |button| button.text.strip == "Global" }
          table = tab && vertex.at_css("#anthropics-claude-models [aria-labelledby='#{tab['id']}'] table")
          raise Error, "Vertex AI Claude Global pricing table not found" unless table

          table
        end

        def find_table(doc, required_header_substrings)
          doc.css("table").find do |table|
            headers = header_texts(table)
            required_header_substrings.all? { |sub| headers.any? { |h| header_match?(h, sub) } }
          end
        end

        def parse_table(table, &)
          headers = header_texts(table)
          model_index = column_index(headers, "Model")
          model_cell = nil
          rows = table.css("tbody tr").filter_map do |tr|
            tds = tr.css("td").to_a
            tds.insert(model_index, model_cell) if model_cell && tds.size == headers.size - 1
            next if tds.size < headers.size

            model_cell = tds[model_index]
            model_id = normalize_model_id(model_name(model_cell))
            [model_id, tds.map { |td| td.text.strip }] if model_id
          end
          rows.group_by(&:first).to_h do |model_id, tiers|
            [model_id, prompt_tier_prices(model_id, tiers.map(&:last), headers, &)]
          end
        end

        def prompt_tier_prices(model_id, rows, headers)
          case rows.map { |cells| cells.join(" ").match(PROMPT_TIER)&.captures }
          in [nil] then yield(rows.first, headers)
          in [["up to", tokens], ["over", ^tokens]]
            above = yield(rows.last, headers).transform_keys { |field| "above_context_#{field}" }
            threshold = { Pricing::Registry::CONTEXT_THRESHOLD_KEY => Integer(tokens.delete(",")) }
            yield(rows.first, headers).merge(above, threshold)
          else
            raise Error, "Anthropic price rows for #{model_id} are not one row or an up-to and over prompt-length pair"
          end
        end

        def header_texts(table)
          rows = table.css("thead tr").map do |tr|
            tr.css("th").flat_map { |th| Array.new([th["colspan"].to_i, 1].max, th.text.strip) }
          end
          rows.first.to_a.zip(*rows.drop(1)).map { |labels| labels.compact.join(" ") }
        end

        def model_name(cell)
          cell.xpath(".//text()").map { |node| node.text.strip }.find { |text| !text.empty? }
        end

        def header_match?(header, substring)
          header.downcase.include?(substring.downcase)
        end

        def column_index(headers, substring)
          index = headers.find_index { |h| header_match?(h, substring) }
          raise Error, "column matching #{substring.inspect} not found in #{headers.inspect}" unless index

          index
        end

        def add_batch_pricing(models)
          models.transform_values do |fields|
            standard = fields.slice("input", "output", "above_context_input", "above_context_output")
            fields.merge(mode_prices(standard, "batch", BATCH_MULTIPLIER))
          end
        end

        def add_data_residency_pricing(models)
          models.each_with_object({}) do |(model_id, fields), priced|
            priced[model_id] = if data_residency_model?(model_id)
                                 fields.merge(mode_prices(fields, "data_residency", DATA_RESIDENCY_MULTIPLIER))
                               else
                                 fields
                               end
          end
        end

        def add_fast_mode_pricing(models, doc)
          table = find_fast_mode_table(doc)
          raise Error, "Anthropic fast mode pricing table not found" unless table

          fast = parse_fast_mode_table(table)
          models.each_with_object({}) do |(model_id, base), priced|
            multiplier = fast_mode_multiplier(base, fast[model_id], model_id)
            priced[model_id] = multiplier ? base.merge(fast_mode_prices(base, multiplier, model_id)) : base
          end
        end

        def find_fast_mode_table(doc)
          doc.css("table").find do |table|
            headers = header_texts(table)
            %w[Model Input Output].all? { |header| headers.include?(header) }
          end
        end

        def parse_fast_mode_table(table)
          headers = header_texts(table)
          model_index = column_index(headers, "Model")
          input_index = column_index(headers, "Input")
          output_index = column_index(headers, "Output")
          table.css("tbody tr").each_with_object({}) do |tr, acc|
            cells = tr.css("td").map { |td| td.text.strip }
            next if cells.size < headers.size

            row = { "input" => parse_price(cells[input_index]), "output" => parse_price(cells[output_index]) }
            cells[model_index].split("/").each do |name|
              model_id = normalize_model_id(name)
              acc[model_id] = row if model_id
            end
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
          prices = mode_prices(base, "fast", multiplier, include_batch: false)
          return prices unless data_residency_model?(model_id)

          residency = (multiplier * DATA_RESIDENCY_MULTIPLIER).round(6)
          prices.merge(mode_prices(base, "fast_data_residency", residency, include_batch: false))
        end

        def mode_prices(fields, mode, multiplier, include_batch: true)
          fields.each_with_object({}) do |(field, value), prices|
            next unless mode_price_field?(field, include_batch: include_batch)

            prices[field.sub(/\A(above_context_)?/, "\\1#{mode}_")] = (value * multiplier).round(6)
          end
        end

        def mode_price_field?(field, include_batch:)
          pattern = include_batch ? /\A(?:above_context_)?(?:batch_)?/ : /\A(?:above_context_)?/
          field.to_s.match?(
            /#{pattern.source}(?:input|output|cache_read_input|cache_write_input|cache_write_extended_input)\z/
          )
        end

        def data_residency_model?(model_id)
          match = model_id.match(/\Aclaude-[a-z]+-(\d+)(?:-(\d+))?\z/)
          return false unless match

          major = match[1].to_i
          minor = match[2].to_i
          major > 4 || (major == 4 && minor >= 5)
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

        def parse_price(text)
          match = text.to_s.match(%r{\$\s*(\d+(?:\.\d+)?)\s*/\s*MTok}i)
          raise Error, "unable to parse price #{text.inspect}" unless match

          Float(match[1])
        end
      end
    end
  end
end
