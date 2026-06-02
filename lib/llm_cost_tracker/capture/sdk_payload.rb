# frozen_string_literal: true

require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/object/try"

module LlmCostTracker
  module Capture
    module SdkPayload
      module_function

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, nested), out| out[key.to_s] = normalize(nested) }
        when Array
          value.map { |nested| normalize(nested) }
        when Symbol
          value.to_s
        when NilClass
          nil
        else
          converted = container_for(value)
          converted ? normalize(converted) : value.deep_dup
        end
      end

      def container_for(value)
        value.try(:deep_to_h) || value.try(:to_h)
      rescue StandardError
        nil
      end
    end
  end
end
