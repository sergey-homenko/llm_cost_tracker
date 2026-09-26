# frozen_string_literal: true

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

        GROUNDING_ROW = "Grounding with Google Search"
        GROUNDING_PRICE = %r{\$([\d.]+)\s*(?:/|per)\s*1,?000}
        PER_IMAGE_PRICE = /\$([\d.]+) per [^$\n]*image/
        TIER_PREFIXES = { "Standard" => "", "Batch" => "batch_", "Flex" => "flex_", "Priority" => "priority_" }.freeze

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = extract_models(doc)
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

        def extract_models(doc)
          article = doc.at_css("div.devsite-article-body")
          raise Error, "Gemini pricing article body not found" unless article

          pair_sections(article).each_with_object({}) do |(model_id, tabs), models|
            next unless model_id

            standard_table = find_table(tabs, "Standard")
            next unless standard_table
            raise Error, "Gemini batch pricing table not found for #{model_id}" unless find_table(tabs, "Batch")

            notes = footnotes(tabs)
            models[model_id] = TIER_PREFIXES.each_with_object({}) do |(heading, prefix), prices|
              table = find_table(tabs, heading)
              prices.merge!(extract_pricing(table, notes: notes, prefix: prefix)) if table
            end.merge(extract_grounding_pricing(standard_table))
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

        def find_table(tabs, heading)
          tabs.css("section").find { |sec| sec.at_css("h3")&.text&.strip == heading }&.at_css("table")
        end

        def footnotes(tabs)
          tabs.xpath("following-sibling::*")
              .take_while { |node| !node["class"]&.include?("models-section") }
              .map(&:text).join
        end

        def extract_grounding_pricing(table)
          row = parse_table(table).find { |label, _| label.to_s.start_with?(GROUNDING_ROW) }
          return {} unless row

          price = row.last.to_s[GROUNDING_PRICE, 1]
          return {} unless price

          { "grounding_request" => Float(price) }
        end

        def extract_pricing(table, notes:, prefix:)
          input = "#{prefix}input"
          output = "#{prefix}output"
          rows = parse_table(table)
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
          return nil if id.match?(/-(?:tts|embedding|live|robotics|computer)/)
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
