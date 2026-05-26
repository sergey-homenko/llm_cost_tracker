# frozen_string_literal: true

require "active_support/core_ext/object/blank"

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        class RenderedLongContextPrices
          def initialize(doc, tier:, fields:, model_ids:)
            @doc = doc
            @tier = tier
            @fields = fields
            @model_ids = model_ids
          end

          def models
            return {} unless table

            table.css("tbody tr").each_with_object({}) do |tr, models|
              cells = tr.css("td").map { |td| td.text.strip }
              next unless cells.size >= 7

              prices = prices_from(cells)
              model_id = @model_ids[cells[0]]
              models[model_id] = prices if model_id && prices
            end
          end

          private

          def table
            @table ||= begin
              root = @doc.at_css(%([data-content-switcher-pane][data-value="#{@tier}"]))
              root&.css("table")&.find { |candidate| candidate.text.include?("Long context") }
            end
          end

          def prices_from(cells)
            long_input = parse_optional_price(cells[4])
            long_cache_read = parse_optional_price(cells[5])
            long_output = parse_optional_price(cells[6])
            return nil unless long_input && long_output

            prices = {
              "_context_price_threshold_tokens" => 272_000,
              "above_context_#{@fields.fetch(:input)}" => long_input,
              "above_context_#{@fields.fetch(:output)}" => long_output
            }
            prices["above_context_#{@fields.fetch(:cache_read_input)}"] = long_cache_read if long_cache_read
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
