# frozen_string_literal: true

module LlmCostTracker
  module ValueHelpers
    class << self
      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, nested_value|
            deep_freeze(key)
            deep_freeze(nested_value)
          end
          value.frozen? ? value : value.freeze
        when Array
          value.each { |nested_value| deep_freeze(nested_value) }
          value.frozen? ? value : value.freeze
        when String
          value.frozen? ? value : value.freeze
        else
          value
        end
      end
    end
  end
end
