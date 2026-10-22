# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "../../../../lib/llm_cost_tracker/pricing/registry"
require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        class RenderedLongContextPrices
          SOURCE_URL = "https://developers.openai.com/api/docs/pricing.md"
          THRESHOLD = /Long context: >(\d+)K input tokens|\(<(\d+)K context length\)/
          LONG_CONTEXT_COLUMNS = {
            input: ["Long context input"], cache_read_input: ["Long context cached input"],
            cache_write_input: ["Long context 30m write", "Long context cache writes"],
            cache_write_extended_input: ["Long context 12h write"], output: ["Long context output"]
          }.freeze
          EXTENDED_WRITE_COLUMN = "Short context 12h write"

          def initialize(markdown, tier:, fields:, model_ids:)
            @markdown = markdown
            @tier = tier
            @fields = fields
            @model_ids = model_ids
          end

          def models
            tables.each_with_object({}) do |(header, *rows), models|
              columns = long_context_columns(header)
              extended = header.index(EXTENDED_WRITE_COLUMN)
              next unless columns || extended

              rows.each do |cells|
                model_id = @model_ids[cells[0]] or next
                prices = row_prices(cells, columns, extended)
                models[model_id] = prices if prices.any?
              end
            end
          end

          private

          def row_prices(cells, columns, extended)
            long = columns && prices_from(columns.transform_values { |index| cells[index] if index })
            extended_price = parse_optional_price(cells[extended]) if extended
            prices = long || {}
            prices[@fields.fetch(:cache_write_extended_input)] = extended_price if extended_price
            prices
          end

          def long_context_columns(header)
            columns = LONG_CONTEXT_COLUMNS.transform_values { |names| header.index { |label| names.include?(label) } }
            columns if columns[:input] && columns[:output]
          end

          def tables
            section.lines.slice_when { |line, following| line.start_with?("|") != following.start_with?("|") }
                   .select { |lines| lines.first.start_with?("|") }
                   .map { |lines| table_cells(lines) }
          end

          def section
            sections = @markdown.scan(/^#### #{@tier}$(.*?)(?=^#|\z)/im)
            sections = @markdown.scan(/^### #{@tier} pricing data$(.*?)(?=^#|\z)/im) if sections.empty?
            sections.join
          end

          def table_cells(lines)
            lines.map { |line| line.split("|")[1..-2].map(&:strip) }.reject { |cells| cells.all?(/\A-+\z/) }
          end

          def prices_from(cells)
            long_input = parse_optional_price(cells[:input])
            long_output = parse_optional_price(cells[:output])
            return nil unless long_input && long_output

            prices = {
              Pricing::Registry::CONTEXT_THRESHOLD_KEY => threshold,
              "above_context_#{@fields.fetch(:input)}" => long_input,
              "above_context_#{@fields.fetch(:output)}" => long_output
            }
            %i[cache_read_input cache_write_input cache_write_extended_input].each do |column|
              price = parse_optional_price(cells[column])
              prices["above_context_#{@fields.fetch(column)}"] = price if price
            end
            prices
          end

          def threshold
            sizes = @markdown.scan(THRESHOLD).flatten.compact.uniq
            raise Error, "OpenAI long-context threshold is not one size on its pricing page: #{sizes}" unless sizes.one?

            Integer(sizes.first) * 1_000
          end

          def parse_optional_price(value)
            text = value.to_s.strip
            return nil if text.blank? || text == "-"

            match = text.match(/\A\$?\s*(\d+(?:\.\d+)?)\z/)
            raise Error, "unable to parse price #{value.inspect}" unless match

            Float(match[1])
          end
        end
      end
    end
  end
end
