# frozen_string_literal: true

module LlmCostTracker
  module Anthropic
    module TierClassification
      DATA_RESIDENCY_GEOS = %w[us].freeze
      STANDARD_EQUIVALENT_SERVICE_TIERS = %w[standard standard_only priority].freeze

      module_function

      def data_residency_geo?(geo)
        DATA_RESIDENCY_GEOS.include?(geo.to_s.downcase)
      end

      def standard_equivalent_tier?(service_tier)
        STANDARD_EQUIVALENT_SERVICE_TIERS.include?(service_tier.to_s)
      end
    end
  end
end
