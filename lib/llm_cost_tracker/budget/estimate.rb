# frozen_string_literal: true

require "bigdecimal"

require_relative "../pricing/estimator"

module LlmCostTracker
  module Budget
    Estimate = Data.define(:total, :largest) do
      def self.for(provider:, model:, request:)
        costs = request_costs(provider, model, request)
        total = costs.sum(BigDecimal("0"))
        new(total: total, largest: costs.max || total)
      end

      def self.request_costs(provider, model, request)
        batch = request["requests"] if request && !model
        return [cost(provider, model, request)] unless batch.is_a?(Array)

        batch.map do |entry|
          params = entry["params"] if entry.is_a?(Hash)
          params.is_a?(Hash) ? cost(provider, params["model"], params) : 0
        end
      end

      def self.cost(provider, model, request)
        return BigDecimal("0") unless provider && model && request

        Pricing::Estimator.call(provider: provider, model: model, request: request) || BigDecimal("0")
      end

      private_class_method :request_costs, :cost
    end
  end
end
