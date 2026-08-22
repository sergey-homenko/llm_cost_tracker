# frozen_string_literal: true

require_relative "section"

module LlmCostTracker
  class Configuration
    class Budgets < Section
      EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze

      attributes :monthly, :daily, :per_call, :on_exceeded
      enum_attribute :exceeded_behavior, allowed: EXCEEDED_BEHAVIORS, default: :notify

      def initialize(owner)
        super
        @monthly = nil
        @daily = nil
        @per_call = nil
        @on_exceeded = nil
        self.exceeded_behavior = :notify
      end
    end
  end
end
