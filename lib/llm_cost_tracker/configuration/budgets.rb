# frozen_string_literal: true

require_relative "section"

module LlmCostTracker
  class Configuration
    class Budgets < Section
      EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze
      TOTALS_SOURCES = %i[ledger cache].freeze

      attributes :monthly, :daily, :per_call, :on_exceeded
      enum_attribute :exceeded_behavior, allowed: EXCEEDED_BEHAVIORS, default: :notify
      enum_attribute :totals_source, allowed: TOTALS_SOURCES, default: :ledger

      def initialize(owner)
        super
        @monthly = nil
        @daily = nil
        @per_call = nil
        @on_exceeded = nil
        self.exceeded_behavior = :notify
        self.totals_source = :ledger
      end
    end
  end
end
