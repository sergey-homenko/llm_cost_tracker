# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    class Calculation
      class Iterations
        def initialize(provider:, requested_mode:, at:)
          @provider = provider
          @requested_mode = requested_mode
          @at = at
          @partial = false
        end

        def price(line_item)
          calculation = calculation_for(line_item.details.to_h.transform_keys(&:to_sym))
          cost = calculation.token_cost
          return line_item unless cost

          @partial ||= calculation.cost_status == Charges::CostStatus::PARTIAL
          status = cost.total.zero? ? Charges::CostStatus::FREE : Charges::CostStatus::COMPLETE
          line_item.with(rate_amount: cost.total, cost: cost.total, currency: cost.currency, cost_status: status)
        end

        def partial?
          @partial
        end

        private

        def calculation_for(details)
          model = details[:model].to_s
          Calculation.for(
            provider: @provider,
            model: model,
            tokens: details.slice(*Usage::TokenUsage.members),
            pricing_mode: mode_for(model),
            at: @at
          )
        end

        def mode_for(model)
          return @requested_mode if Matcher.modifier_priced?(provider: @provider, model: model, modifier: "fast")

          Mode.compose(Mode.tokenize(@requested_mode) - ["fast"])
        end
      end
    end
  end
end
