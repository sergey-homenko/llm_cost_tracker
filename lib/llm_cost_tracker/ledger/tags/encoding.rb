# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Ledger
    module Tags
      module Encoding
        INDEXABLE_BYTES = 2_048

        def self.encode(value)
          encoded = case value
                    when Hash then JSON.generate(normalize_hash(value))
                    when Array then JSON.generate(normalize_array(value))
                    else value.to_s
                    end
          truncate(encoded)
        end

        def self.truncate(string)
          limit = [LlmCostTracker.configuration.tags.max_value_bytesize.to_i, INDEXABLE_BYTES].min
          return string if string.bytesize <= limit

          string.byteslice(0, limit).encode("UTF-8", invalid: :replace, undef: :replace)
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
