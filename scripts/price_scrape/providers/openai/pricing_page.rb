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

          def initialize(doc)
            @doc = doc
          end

          def tier_rows(tier)
            props = pricing_props(@doc).find { |candidate| unwrap(candidate["tier"]) == tier }
            raise Error, "OpenAI #{tier} pricing table not found" unless props

            rows = unwrap(props["rows"])
            raise Error, "OpenAI standard pricing rows not found" unless rows.is_a?(Array)

            rows
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
            groups.is_a?(Array) ? groups : []
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
