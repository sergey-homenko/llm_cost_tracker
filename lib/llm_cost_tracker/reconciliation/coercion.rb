# frozen_string_literal: true

require "json"
require "time"

module LlmCostTracker
  module Reconciliation
    module Coercion
      def self.symbolize(hash)
        return hash if hash.is_a?(Hash) && hash.keys.all?(Symbol)

        hash.to_h.transform_keys(&:to_sym)
      end

      def self.normalized_epoch(value)
        return value.to_i if value.is_a?(Numeric)

        Time.parse(value.to_s).utc.to_i
      rescue ArgumentError
        value.to_s
      end

      def self.coerce_hash(response, label:)
        return {} if response.nil?
        return symbolize(response) if response.is_a?(Hash)

        parsed = JSON.parse(response.to_s)
        raise ArgumentError, "#{label} payload must be a JSON object" unless parsed.is_a?(Hash)

        symbolize(parsed)
      rescue JSON::ParserError => e
        raise ArgumentError, "Unable to parse #{label} payload: #{e.message}"
      end
    end
  end
end
