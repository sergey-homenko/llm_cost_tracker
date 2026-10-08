# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module Percent
      def self.of(part, whole)
        whole = whole.to_f
        whole.positive? ? (part.to_f / whole) * 100.0 : 0.0
      end
    end
  end
end
