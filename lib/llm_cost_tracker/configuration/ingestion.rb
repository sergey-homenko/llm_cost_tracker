# frozen_string_literal: true

require_relative "section"

module LlmCostTracker
  class Configuration
    class Ingestion < Section
      MODES = %i[inline async].freeze

      attributes :pool_size
      enum_attribute :mode, allowed: MODES, default: :inline

      def initialize(owner)
        super
        @pool_size = nil
        self.mode = :inline
      end
    end
  end
end
