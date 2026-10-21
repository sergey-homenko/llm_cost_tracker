# frozen_string_literal: true

require "json"

require_relative "../base"
require_relative "astro_payload"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        class PricingPage
          include AstroPayload

          PRICING_COMPONENT = "/pricing."
          SPECIALIZED_PRICING = "#content-switcher-specialized-pricing"
          TIER_PANE = "[data-content-switcher-pane]"
          TIER_ROWS = { "flex" => %w[batch alternateRows] }.freeze
          PRICE_HEADINGS = ["Input", "Cached input", "Output"].freeze

          def initialize(doc)
            @doc = doc
          end

          def tier_rows(tier)
            table_tier, rows_key = TIER_ROWS.fetch(tier, [tier, "rows"])
            tables = pricing_props(@doc).select do |candidate|
              unwrap(candidate["tier"]) == table_tier && candidate.key?(rows_key)
            end
            raise Error, "OpenAI #{tier} pricing table not found" if tables.empty?

            rows = tables.map { |props| unwrap(props[rows_key]) }
            raise Error, "OpenAI standard pricing rows not found" unless rows.all?(Array)

            rows.flatten(1)
          end

          def specialized_groups(tier)
            pane = @doc.at_css(SPECIALIZED_PRICING)&.at_css(%(#{TIER_PANE}[data-value="#{tier}"]))
            props = pane && pricing_props(pane).find { |candidate| candidate.key?("groups") }
            groups(props) if props
          end

          def untiered_groups(tier)
            pricing_islands(@doc).select { |island| shown_under?(island, tier) }.filter_map do |island|
              props = parse(island)
              groups(props) unless props.key?("tier")
            end
          end

          def tool_rows
            table = @doc.css("table").find { |candidate| candidate.text.include?("ToolDetailsPricing") }
            raise Error, "OpenAI tool pricing table not found" unless table

            table.css("tbody tr").map { |tr| tr.css("td").map { |td| td.text.gsub(/\s+/, " ").strip } }
          end

          private

          def pricing_islands(node)
            node.css("astro-island").select { |island| island["component-url"].to_s.include?(PRICING_COMPONENT) }
          end

          def pricing_props(node) = pricing_islands(node).map { |island| parse(island) }

          def parse(island)
            JSON.parse(island["props"].to_s)
          rescue JSON::ParserError => e
            raise Error, "unable to parse OpenAI pricing payload: #{e.message}"
          end

          def groups(props)
            groups = unwrap(props["groups"])
            return [] unless groups.is_a?(Array)

            order = price_column_order(props)
            order ? groups.map { |group| ordered_group(unwrap(group), order) } : groups
          end

          def price_column_order(props)
            headings = unwrap(props["headings"])
            return unless headings.is_a?(Array)

            labels = headings.drop(1).map { |heading| heading_label(heading).to_s }
            prices = PRICE_HEADINGS.map { |name| labels.index { |label| label.start_with?(name) } }
            ((0...labels.size).to_a - prices) + prices if prices.all?
          end

          def heading_label(heading)
            heading = unwrap(heading)
            tooltip = unwrap(heading["__pricingTooltipHeading"]) if heading.is_a?(Hash)
            tooltip.is_a?(Hash) ? unwrap(tooltip["label"]) : heading
          end

          def ordered_group(group, order)
            rows = unwrap(group["rows"]) if group.is_a?(Hash)
            return group unless rows.is_a?(Array)

            group.merge("rows" => rows.map { |row| ordered_cells(unwrap(row), order) })
          end

          def ordered_cells(cells, order)
            cells.is_a?(Array) && cells.size == order.size ? cells.values_at(*order) : cells
          end

          def shown_under?(island, tier)
            pane = island.ancestors(TIER_PANE).first
            TIER_FIELDS.fetch((pane && pane["data-value"]) || "standard", STANDARD_FIELDS) == TIER_FIELDS.fetch(tier)
          end
        end
      end
    end
  end
end
