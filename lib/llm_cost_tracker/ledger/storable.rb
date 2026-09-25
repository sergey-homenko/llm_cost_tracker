# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Storable
      def self.clean(value)
        case value
        when Hash then value.to_h { |key, nested| [clean(key), clean(nested)] }
        when Array then value.map { |nested| clean(nested) }
        when String then value.dup.force_encoding(Encoding::UTF_8).scrub.delete("\u0000")
        else value
        end
      end
    end
  end
end
