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
            cache_write_input: ["Long context 30m write", "Long context cache writes"], output: ["Long context output"]
          }.freeze

          def initialize(markdown, tier:, fields:, model_ids:)
            @markdown = markdown
            @tier = tier
            @fields = fields
            @model_ids = model_ids
          end

          def models
            tables.each_with_object({}) do |(header, *rows), models|
              columns = long_context_columns(header) or next

              rows.each do |cells|
                model_id = @model_ids[cells[0]] or next
                prices = prices_from(columns.transform_values { |index| cells[index] if index })
                models[model_id] = prices if prices
              end
            end
          end

          private

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
            (@markdown[/^#### #{@tier}$(.*?)(?=^#|\z)/im, 1] ||
              @markdown[/^### #{@tier} pricing data$(.*?)(?=^#|\z)/im, 1]).to_s
          end

          def table_cells(lines)
            lines.map { |line| line.split("|")[1..-2].map(&:strip) }.reject { |cells| cells.all?(/\A-+\z/) }
          end

          def prices_from(cells)
            long_input = parse_optional_price(cells[:input])
            long_cache_read = parse_optional_price(cells[:cache_read_input])
            long_cache_write = parse_optional_price(cells[:cache_write_input])
            long_output = parse_optional_price(cells[:output])
            return nil unless long_input && long_output

            prices = {
              Pricing::Registry::CONTEXT_THRESHOLD_KEY => threshold,
              "above_context_#{@fields.fetch(:input)}" => long_input,
              "above_context_#{@fields.fetch(:output)}" => long_output
            }
            prices["above_context_#{@fields.fetch(:cache_read_input)}"] = long_cache_read if long_cache_read
            prices["above_context_#{@fields.fetch(:cache_write_input)}"] = long_cache_write if long_cache_write
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
