# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Ledger
    module Tags
      module Encoding
        def self.encode(value)
          case value
          when Hash then JSON.generate(normalize_hash(value))
          when Array then JSON.generate(normalize_array(value))
          else value.to_s
          end
        end

        def self.normalize_hash(hash)
          hash.transform_keys(&:to_s).sort.to_h.transform_values { |v| normalize_value(v) }
        end

        def self.normalize_array(array)
          array.map { |v| normalize_value(v) }
        end

        def self.normalize_value(value)
          case value
          when Hash then normalize_hash(value)
          when Array then normalize_array(value)
          else value.to_s
          end
        end
      end
    end
  end
end
