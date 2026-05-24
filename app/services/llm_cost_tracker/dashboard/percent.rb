# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module Percent
      def self.of(numerator, denominator)
        denominator = denominator.to_f
        return 0.0 unless denominator.positive?

        (numerator.to_f / denominator) * 100.0
      end
    end
  end
end
