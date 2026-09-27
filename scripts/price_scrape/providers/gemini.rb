# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini < Base
        source_url "https://ai.google.dev/gemini-api/docs/pricing"
        min_models 5
        max_price 1000.0
        anchors "gemini-2.5-pro", "gemini-2.5-flash"

        SERVICE_ROWS = {
          "grounding_request" => /\AGrounding with Google (?:Search|Web and Image Search)/,
          "maps_grounding_request" => /\AGrounding with Google Maps/
        }.freeze
        GROUNDING_PRICE = %r{\$([\d.]+)\s*(?:/|per)\s*1,?000}
        STORAGE_PRICE = %r{\$([\d.]+)\s*/\s*1,000,000 tokens per hour}
        PER_IMAGE_PRICE = /\$([\d.]+) per [^$\n]*image/
        TIER_PREFIXES = { "Standard" => "", "Batch" => "batch_", "Flex" => "flex_", "Priority" => "priority_" }.freeze
        EMBEDDING_ROWS = {
          "Text input price" => "input",
          "Image input price" => "image_input",
          "Audio input price" => "audio_input",
          "Video input price" => "video_input"
        }.freeze
        SCHEDULED_FROM = /starting (\w+ \d{1,2}, \d{4})/
        SCHEDULED_LINE = /#{SCHEDULED_FROM}\.?\z/
        CURRENT_LINE = /through \w+ \d{1,2}, \d{4}\.?\z/
        TEXT_PRICED_AS = /Text input and output\s+is priced the same as/

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = extract_models(doc, Date.parse(scraped_at.to_s))
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: [],
            service_charges: {}
          )
        end

        private

        def extract_models(doc, today)
          article = doc.at_css("div.devsite-article-body")
          raise Error, "Gemini pricing article body not found" unless article

          text_priced_as = {}
          models = pair_sections(article).each_with_object({}) do |(model_ids, tabs, same_as), collected|
            next if model_ids.empty? || !find_table(tabs, "Standard")
            raise Error, "Gemini batch pricing table not found for #{model_ids.first}" unless find_table(tabs, "Batch")

            prices = dated_prices(tabs, footnotes(tabs), today)
            model_ids.each do |model_id|
              collected[model_id] = prices.dup
              text_priced_as[model_id] = same_as if same_as && !prices.key?("output")
            end
          end
          add_text_output_prices(models, text_priced_as)
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

        def dated_prices(tabs, notes, today)
          starting = tabs.text[SCHEDULED_FROM, 1]
          return section_prices(tabs, notes) unless starting

          from = Date.parse(starting)
          scheduled = section_prices(without_lines(tabs, CURRENT_LINE), notes)
          return scheduled if from <= today

          current = section_prices(without_lines(tabs, SCHEDULED_LINE), notes)
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

        def section_prices(tabs, notes)
          TIER_PREFIXES.each_with_object({}) do |(heading, prefix), prices|
            table = find_table(tabs, heading)
            prices.merge!(extract_pricing(table, notes: notes, prefix: prefix)) if table
          end.merge(extract_service_pricing(find_table(tabs, "Standard")))
        end

        def pair_sections(article)
          current_model_ids = []
          same_as = nil
          article.children.each_with_object([]) do |child, pairs|
            next if child.text?
            next unless child.respond_to?(:css)

            if child["class"]&.include?("models-section")
              codes = child.css("div.heading-group code")
              current_model_ids = codes.filter_map { |code| normalize_model_id(code.text.strip) }
            elsif pricing_tabs_container?(child)
              pairs << [current_model_ids, child, same_as]
              current_model_ids = []
              same_as = nil
            elsif child.text.match?(TEXT_PRICED_AS)
              same_as = child.at_css("a[href^='#']")&.[]("href").to_s.delete_prefix("#")
            end
          end
        end

        def pricing_tabs_container?(child)
          child["class"]&.include?("ds-selector-tabs") ||
            child.at_css("devsite-selector[data-ds-scope='code-sample']") ||
            (child["data-ds-scope"] == "code-sample")
        end

        def find_table(tabs, heading)
          tabs.css("section").find { |sec| sec.at_css("h3")&.text&.strip == heading }&.at_css("table")
        end

        def footnotes(tabs)
          tabs.xpath("following-sibling::*")
              .take_while { |node| !node["class"]&.include?("models-section") }
              .map(&:text).join
        end

        def extract_service_pricing(table)
          rows = parse_table(table)
          prices = SERVICE_ROWS.each_with_object({}) do |(key, label), acc|
            price = rows.find { |row_label, _| row_label.match?(label) }&.last.to_s[GROUNDING_PRICE, 1]
            acc[key] = Float(price) if price
          end
          storage = rows.find { |label, _| label.start_with?("Context caching") }&.last.to_s[STORAGE_PRICE, 1]
          prices["cache_storage_token_hour"] = Float(storage) if storage
          prices
        end

        def extract_pricing(table, notes:, prefix:)
          input = "#{prefix}input"
          output = "#{prefix}output"
          rows = parse_table(table)
          if rows.key?("Text input price")
            return EMBEDDING_ROWS.each_with_object({}) do |(label, key), prices|
              prices["#{prefix}#{key}"] = parse_price(rows[label]) if rows[label]&.match?(/\$\s*\d/)
            end
          end

          input_key = rows.keys.find { |k| k.start_with?("Input price") }
          output_key = rows.keys.find { |k| k.start_with?("Output price") }
          raise Error, "Gemini text pricing rows not found" unless input_key && output_key

          prices = token_prices(rows,
                                notes: notes,
                                input_key: input_key,
                                output_key: output_key,
                                input: input,
                                output: output)
          add_context_tier_prices(prices,
                                  rows,
                                  input_key: input_key,
                                  output_key: output_key,
                                  input: input,
                                  output: output)
          add_cache_read_prices(prices, rows, cache_read_input: "#{prefix}cache_read_input")
          prices
        end

        def token_prices(rows, notes:, input_key:, output_key:, input:, output:)
          prices = { input => parse_price(rows[input_key]) }
          prices[output] = parse_price(rows[output_key]) unless rows[output_key].start_with?(PER_IMAGE_PRICE)
          prices[input.sub("input", "image_input")] = prices[input]
          audio_input = parse_modality_price(rows[input_key], "audio")
          # An input price without a modality label covers audio too.
          audio_input ||= prices[input] unless rows[input_key].include?("(")
          prices[audio_price_key(input)] = audio_input if audio_input
          audio_output = parse_modality_price(rows[output_key], "audio")
          prices[audio_price_key(output)] = audio_output if audio_output
          image_output = parse_modality_price(rows[output_key], "images") || per_image_rate(rows[output_key], notes)
          prices[output.sub("output", "image_output")] = image_output if image_output
          prices
        end

        def add_context_tier_prices(prices, rows, input_key:, output_key:, input:, output:)
          input_tiers = parse_prompt_tier_prices(rows[input_key])
          output_tiers = parse_prompt_tier_prices(rows[output_key])
          return unless input_tiers && output_tiers

          prices["_context_price_threshold_tokens"] = 200_000
          prices["above_context_#{input}"] = input_tiers.fetch(1)
          prices["above_context_#{input.sub('input', 'image_input')}"] = input_tiers.fetch(1)
          prices["above_context_#{audio_price_key(input)}"] = input_tiers.fetch(1)
          prices["above_context_#{output}"] = output_tiers.fetch(1)
        end

        def add_cache_read_prices(prices, rows, cache_read_input:)
          context_cache_key = rows.keys.find { |k| k.start_with?("Context caching price") }
          return unless context_cache_key && rows[context_cache_key].match?(/\$\s*\d/)

          prices[cache_read_input] = parse_price(rows[context_cache_key])
          audio = parse_modality_price(rows[context_cache_key], "audio")
          prices[cache_read_input.sub("cache_read", "audio_cache_read")] = audio if audio
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

        def normalize_model_id(id)
          return nil if id.match?(/-(?:live|streaming)\b/)

          id if id.match?(/\Agemini-(?:\d+(?:\.\d+)?-(?:pro|flash)|embedding-2|robotics-er-\d)/)
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

        def per_image_rate(text, notes)
          image_price = text[PER_IMAGE_PRICE, 1]
          return unless image_price

          rate, note_price = notes.match(
            /Image output is priced at \$([\d.]+) per 1,000,000 tokens.*?\$([\d.]+) per\s+image/m
          )&.captures
          raise Error, "Gemini image output rate not found" unless rate

          # The footnote gives the Standard rate; Batch, Flex and Priority cells differ only in per-image price.
          (Float(rate) * Float(image_price) / Float(note_price)).round(4)
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
