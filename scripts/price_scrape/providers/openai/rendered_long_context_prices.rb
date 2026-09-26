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

          def initialize(markdown, tier:, fields:, model_ids:)
            @markdown = markdown
            @tier = tier
            @fields = fields
            @model_ids = model_ids
          end

          def models
            rows.each_with_object({}) do |cells, models|
              model_id = @model_ids[cells[0]]
              next unless model_id && cells.size >= 9

              prices = prices_from(cells)
              models[model_id] = prices if prices
            end
          end

          private

          def rows
            section = @markdown[/^### #{@tier} pricing data$(.*?)(?=^#|\z)/im, 1].to_s
            section.lines.filter_map { |line| line.split("|")[1..-2].map(&:strip) if line.start_with?("|") }
          end

          def prices_from(cells)
            long_input = parse_optional_price(cells[5])
            long_cache_read = parse_optional_price(cells[6])
            long_cache_write = parse_optional_price(cells[7])
            long_output = parse_optional_price(cells[8])
            return nil unless long_input && long_output

            prices = {
              Pricing::Registry::CONTEXT_THRESHOLD_KEY => 272_000,
              "above_context_#{@fields.fetch(:input)}" => long_input,
              "above_context_#{@fields.fetch(:output)}" => long_output
            }
            prices["above_context_#{@fields.fetch(:cache_read_input)}"] = long_cache_read if long_cache_read
            prices["above_context_#{@fields.fetch(:cache_write_input)}"] = long_cache_write if long_cache_write
            prices
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
