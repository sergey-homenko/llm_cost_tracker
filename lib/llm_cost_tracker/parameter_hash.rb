# frozen_string_literal: true

module LlmCostTracker
  module ParameterHash
    class << self
      def to_hash(value)
        return {} if value.nil?

        unsafe_hash = value.try(:to_unsafe_h)
        return unsafe_hash if unsafe_hash.is_a?(Hash)
        return value if value.is_a?(Hash)

        hash = value.try(:to_h)
        hash.is_a?(Hash) ? hash : {}
      rescue ArgumentError, TypeError
        {}
      end

      def with_indifferent_access(value)
        to_hash(value).with_indifferent_access
      end
    end
  end
end
