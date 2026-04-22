# frozen_string_literal: true

module LlmCostTracker
  module ParameterHash
    class << self
      def hash_like?(value)
        value.is_a?(Hash) || action_controller_parameters?(value)
      end

      def to_hash(value)
        return {} if value.nil?
        return value.to_unsafe_h if action_controller_parameters?(value)
        return value.to_h if value.is_a?(Hash)
        return {} unless value.respond_to?(:to_h)

        hash = value.to_h
        hash.is_a?(Hash) ? hash : {}
      rescue ArgumentError, TypeError
        {}
      end

      def with_indifferent_access(value)
        to_hash(value).with_indifferent_access
      end

      private

      def action_controller_parameters?(value)
        defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)
      end
    end
  end
end
