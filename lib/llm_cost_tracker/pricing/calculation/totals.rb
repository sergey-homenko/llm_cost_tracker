# frozen_string_literal: true

require "bigdecimal"

module LlmCostTracker
  module Pricing
    class Calculation
      module Totals
        class << self
          def token_cost(token_lines, currency)
            Charges::Cost.new(components: components(token_lines).freeze, total: sum(token_lines), currency: currency)
          end

          def in_call_currency(service_lines, token_cost)
            return service_lines if service_lines.empty?

            currency = token_cost&.currency || service_lines.first.currency || LlmCostTracker::DEFAULT_CURRENCY
            counted, dropped = service_lines.partition { |line| line.currency.to_s == currency.to_s }
            warn_currency_mismatch(dropped, currency) if dropped.any?
            counted
          end

          def with_service_lines(token_cost, service_lines)
            return token_cost if service_lines.empty?

            Charges::Cost.new(
              components: token_cost ? token_cost.components : {}.freeze,
              total: (token_cost&.total || BigDecimal("0")) + sum(service_lines),
              currency: (token_cost&.currency || service_lines.first.currency).to_s
            )
          end

          private

          def components(token_lines)
            by_component = token_lines.group_by { |line| line.dimension.parent || line.dimension.key }
            Usage::Catalog.token_priced.each_with_object({}) do |dimension, components|
              lines = by_component.fetch(dimension.key, [])
              components[dimension.cost_key] = sum(lines) unless lines.any?(&:unpriced?)
            end
          end

          def sum(lines)
            lines.sum(BigDecimal("0")) { |line| line.cost_value.round(8) }
          end

          def warn_currency_mismatch(lines, base_currency)
            currencies = lines.map { |line| line.currency.to_s }.uniq.sort
            Logging.warn(
              "Service line currency mismatch: header is #{base_currency}, dropping " \
              "#{lines.size} priced line(s) in #{currencies.join(', ')} from header total. " \
              "Per-line costs are still recorded; header total reflects #{base_currency} only."
            )
          end
        end
      end
    end
  end
end
