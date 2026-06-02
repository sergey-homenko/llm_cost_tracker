# frozen_string_literal: true

module LlmCostTracker
  module Usage
    Dimension = Data.define(
      :key, :kind, :direction, :modality, :cache_state, :unit, :rate_basis
    ) do
      def token?
        unit == "token"
      end

      def token_key
        :"#{key}_tokens" if token?
      end

      def cost_key
        :"#{key}_cost" if token?
      end
    end
  end
end
