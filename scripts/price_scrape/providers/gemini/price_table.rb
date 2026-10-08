# frozen_string_literal: true

require "nokogiri"

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini < Base
        class PriceTable
          CONTEXT_THRESHOLD = Pricing::Registry::CONTEXT_THRESHOLD_KEY
          PRICE = /\$\s*(\d+(?:\.\d+)?)/
          PRICED = /\$\s*\d/
          PER_IMAGE_PRICE = /\$([\d.]+) per [^$\n]*image/
          IMAGE_OUTPUT_NOTE = /Image output is priced at \$([\d.]+) per 1,000,000 tokens.*?\$([\d.]+) per\s+image/m
          PROMPT_TIER = /prompts?\s*>/i
          PROMPT_TIER_SIZE = /prompts?\s*>\s*(\d+)k\b/i
          GROUNDING_PRICE = %r{\$([\d.]+)\s*(?:/|per)\s*1,?000}
          SERVICE_ROWS = {
            "grounding_request" => [/\AGrounding with Google (?:Search|Web and Image Search)/, GROUNDING_PRICE],
            "maps_grounding_request" => [/\AGrounding with Google Maps/, GROUNDING_PRICE],
            "cache_storage_token_hour" => [/\AContext caching/, %r{\$([\d.]+)\s*/\s*1,000,000 tokens per hour}]
          }.freeze
          EMBEDDING_ROWS = {
            "Text input price" => "input", "Image input price" => "image_input",
            "Audio input price" => "audio_input", "Video input price" => "video_input"
          }.freeze

          def initialize(table, notes)
            @rows = table.css("tbody tr").each_with_object({}) do |tr, rows|
              cells = tr.css("td").map { |td| cell_text(td) }
              rows[cells[0]] = cells[2] if cells.size >= 3
            end
            @notes = notes
          end

          def prices(prefix)
            prices = @rows.key?("Text input price") ? embedding_prices : token_prices
            prices.transform_keys do |field|
              field == CONTEXT_THRESHOLD ? field : field.sub(/\A(above_context_)?/, "\\1#{prefix}")
            end
          end

          def service_prices
            SERVICE_ROWS.each_with_object({}) do |(field, (label, pattern)), prices|
              price = @rows.find { |row_label, _| row_label.match?(label) }&.last.to_s[pattern, 1]
              prices[field] = Float(price) if price
            end
          end

          private

          def embedding_prices
            EMBEDDING_ROWS.each_with_object({}) do |(label, field), prices|
              prices[field] = parse_price(@rows[label]) if @rows[label]&.match?(PRICED)
            end
          end

          def token_prices
            input = row("Input price")
            output = row("Output price")
            raise Error, "Gemini text pricing rows not found" unless input && output

            prices = modality_prices(input, output).merge(context_tier_prices(input, output))
            prices.merge(cache_prices(row("Context caching price"), prices[CONTEXT_THRESHOLD]))
          end

          def modality_prices(input, output)
            base = parse_price(input)
            prices = { "input" => base }
            prices["output"] = parse_price(output) unless output.start_with?(PER_IMAGE_PRICE)
            prices.merge(
              "image_input" => base,
              "audio_input" => input.include?("(") ? modality_price(input, "audio") : base,
              "audio_output" => modality_price(output, "audio"),
              "image_output" => modality_price(output, "images") || per_image_rate(output),
              "video_output" => modality_price(output, "video")
            ).compact
          end

          def context_tier_prices(input, output)
            input_tiers = prompt_tier_prices(input)
            output_tiers = prompt_tier_prices(output)
            return {} unless input_tiers && output_tiers

            thresholds = [input, output].map { |text| prompt_threshold(text) }.uniq
            raise Error, "Gemini input and output prompt tiers split at different sizes" if thresholds.size > 1

            above_input = input_tiers.fetch(1)
            {
              CONTEXT_THRESHOLD => thresholds.first,
              "above_context_input" => above_input, "above_context_image_input" => above_input,
              "above_context_audio_input" => above_input, "above_context_output" => output_tiers.fetch(1)
            }
          end

          def cache_prices(text, threshold)
            return {} unless text&.match?(PRICED)

            prices = {
              "cache_read_input" => parse_price(text), "audio_cache_read_input" => modality_price(text, "audio")
            }.compact
            prices.merge(above_context_cache_price(text, threshold))
          end

          def above_context_cache_price(text, threshold)
            tiers = prompt_tier_prices(text)
            return {} unless tiers
            unless prompt_threshold(text) == threshold
              raise Error, "Gemini context caching prompt tier splits at a different size"
            end

            { "above_context_cache_read_input" => tiers.fetch(1) }
          end

          def row(label) = @rows.find { |row_label, _| row_label.start_with?(label) }&.last

          def cell_text(cell)
            Nokogiri::HTML.fragment(cell.inner_html.gsub(%r{<br\s*/?>}i, "\n")).text.strip
          end

          def parse_price(text)
            match = text.to_s.match(PRICE)
            raise Error, "unable to parse price #{text.inspect}" unless match

            Float(match[1])
          end

          def modality_price(text, modality)
            pattern = /\([^)]*\b#{Regexp.escape(modality)}\b[^)]*\)/i
            line = text.lines.find { |candidate| candidate.match?(pattern) }
            parse_price(line) if line
          end

          def per_image_rate(text)
            image_price = text[PER_IMAGE_PRICE, 1]
            return unless image_price

            standard_rate, standard_image_price = @notes.match(IMAGE_OUTPUT_NOTE)&.captures
            raise Error, "Gemini image output rate not found" unless standard_rate

            (Float(standard_rate) * Float(image_price) / Float(standard_image_price)).round(4)
          end

          def prompt_tier_prices(text)
            return unless text.match?(PROMPT_TIER)

            prices = text.scan(PRICE).flatten.map { |price| Float(price) }
            prices.first(2) if prices.size >= 2
          end

          def prompt_threshold(text)
            size = text[PROMPT_TIER_SIZE, 1]
            raise Error, "Gemini prompt tier size not found in #{text.inspect}" unless size

            Integer(size) * 1_000
          end
        end
      end
    end
  end
end
