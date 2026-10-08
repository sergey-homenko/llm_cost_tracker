# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Anthropic < Base
        class PriceTable
          PROMPT_TIER = /for prompts (up to|over) ([\d,]+) tokens/
          PRICE = %r{\$\s*(\d+(?:\.\d+)?)\s*/\s*MTok}i

          def self.find(doc, model_ids, &)
            doc.css("table").map { |node| new(node, model_ids) }.find(&)
          end

          def initialize(node, model_ids)
            @node = node
            @model_ids = model_ids
          end

          def headers
            @headers ||= begin
              rows = @node.css("thead tr").map do |tr|
                tr.css("th").flat_map { |th| Array.new([th["colspan"].to_i, 1].max, th.text.strip) }
              end
              rows.first.to_a.zip(*rows.drop(1)).map { |labels| labels.compact.join(" ") }
            end
          end

          def headers?(substrings)
            substrings.all? { |substring| headers.any? { |header| header_match?(header, substring) } }
          end

          def prices(columns)
            model_rows.group_by(&:first).to_h do |model_id, rows|
              [model_id, prompt_tier_prices(model_id, rows.map(&:last), columns)]
            end
          end

          def fast_prices
            model, input, output = %w[Model Input Output].map { |header| column(header) }
            full_rows.each_with_object({}) do |cells, prices|
              row = { "input" => parse_price(cells[input]), "output" => parse_price(cells[output]) }
              cells[model].split("/").filter_map { |name| @model_ids.call(name) }.each { |id| prices[id] = row }
            end
          end

          def retired_names
            @node.css("tbody tr").filter_map do |tr|
              model_name(tr.at_css("td")) if tr.at_css("td [aria-label*='(Retired)']")
            end
          end

          private

          def model_rows
            index = column("Model")
            spanned_rows(index).filter_map do |tds|
              model_id = @model_ids.call(model_name(tds[index]))
              [model_id, tds.map { |td| td.text.strip }] if model_id
            end
          end

          def full_rows
            rows = @node.css("tbody tr").map { |tr| tr.css("td").map { |td| td.text.strip } }
            rows.reject { |cells| cells.size < headers.size }
          end

          def spanned_rows(model_index)
            model_cell = nil
            @node.css("tbody tr").filter_map do |tr|
              tds = tr.css("td").to_a
              tds.insert(model_index, model_cell) if model_cell && tds.size == headers.size - 1
              next if tds.size < headers.size

              model_cell = tds[model_index]
              tds
            end
          end

          def prompt_tier_prices(model_id, rows, columns)
            case rows.map { |cells| cells.join(" ").match(PROMPT_TIER)&.captures }
            in [nil] then row_prices(rows.first, columns)
            in [["up to", tokens], ["over", ^tokens]]
              above = row_prices(rows.last, columns).transform_keys { |field| "above_context_#{field}" }
              threshold = { Pricing::Registry::CONTEXT_THRESHOLD_KEY => Integer(tokens.delete(",")) }
              row_prices(rows.first, columns).merge(above, threshold)
            else
              message = "Anthropic price rows for #{model_id} are not one row " \
                        "or an up-to and over prompt-length pair"
              raise Error, message
            end
          end

          def row_prices(cells, columns)
            columns.transform_values { |header| parse_price(cells[column(header)]) }
          end

          def column(substring)
            index = headers.find_index { |header| header_match?(header, substring) }
            raise Error, "column matching #{substring.inspect} not found in #{headers.inspect}" unless index

            index
          end

          def header_match?(header, substring) = header.downcase.include?(substring.downcase)

          def model_name(cell)
            cell.xpath(".//text()").map { |node| node.text.strip }.find { |text| !text.empty? }
          end

          def parse_price(text)
            match = text.to_s.match(PRICE)
            raise Error, "unable to parse price #{text.inspect}" unless match

            Float(match[1])
          end
        end
      end
    end
  end
end
