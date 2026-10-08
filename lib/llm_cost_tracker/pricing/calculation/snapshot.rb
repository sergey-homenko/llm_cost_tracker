# frozen_string_literal: true

require "bigdecimal/util"

module LlmCostTracker
  module Pricing
    class Calculation
      module Snapshot
        SCHEMA_VERSION = 1

        class << self
          def for_match(match, service_lines, token_lines)
            {
              "schema_version" => SCHEMA_VERSION,
              "source" => match.source.name,
              "source_key" => match.key,
              "source_version" => match.source.version,
              "matched_by" => match.matched_by.to_s,
              "currency" => match.source.currency,
              "rates" => rates(service_lines).merge(rates(token_lines))
            }
          end

          def for_service_charges(lines, currency)
            {
              "schema_version" => SCHEMA_VERSION,
              "source" => lines.first.price_source,
              "source_version" => lines.first.price_source_version,
              "matched_by" => "service_charges",
              "currency" => currency,
              "rates" => rates(lines)
            }
          end

          private

          def rates(line_items)
            line_items.each_with_object({}) do |line_item, rates|
              next if line_item.price_key.nil? || line_item.rate_amount.nil?

              rates[line_item.price_key] ||= {
                "amount" => line_item.rate_amount.to_d.to_s("F"),
                "quantity" => Integer(line_item.rate_quantity)
              }
            end
          end
        end
      end
    end
  end
end
