# frozen_string_literal: true

module LlmCostTracker
  module Reconciliation
    module Masking
      SENSITIVE_KEYS = %i[provider_api_key_id provider_workspace_id provider_organization_id].to_set.freeze
      MASK_TAIL_LENGTH = 4

      module_function

      def mask_value(key, value)
        string = value.to_s
        return string unless SENSITIVE_KEYS.include?(key.to_sym)
        return string if string.length <= MASK_TAIL_LENGTH

        "***#{string[-MASK_TAIL_LENGTH, MASK_TAIL_LENGTH]}"
      end

      def format_attribution(attribution, separator: ", ")
        return "" if attribution.nil? || attribution.empty?

        attribution.map { |key, value| "#{key}=#{mask_value(key, value)}" }.join(separator)
      end
    end
  end
end
