# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Ledger
    module Tags
      module Encoding
        INDEXABLE_BYTES = 2_048

        def self.encode(value)
          encoded = case value
                    when Hash, Array then JSON.generate(normalize_value(value))
                    else value.to_s
                    end
          truncate(encoded)
        end

        def self.truncate(string)
          limit = [LlmCostTracker.configuration.tags.max_value_bytesize.to_i, INDEXABLE_BYTES].min
          return string if string.bytesize <= limit

          string.byteslice(0, limit).encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def self.normalize_value(value)
          case value
          when Hash then value.transform_keys(&:to_s).sort.to_h.transform_values { |v| normalize_value(v) }
          when Array then value.map { |v| normalize_value(v) }
          else value.to_s
          end
        end
      end
    end
  end
end
