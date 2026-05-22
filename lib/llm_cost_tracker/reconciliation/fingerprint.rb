# frozen_string_literal: true

require "digest"

module LlmCostTracker
  module Reconciliation
    module Fingerprint
      DIGEST_LENGTH = 16

      module_function

      def compute(keys, attributes)
        source_string = keys.map { |key| attributes[key].to_s }.join("|")
        Digest::SHA256.hexdigest(source_string)[0, DIGEST_LENGTH]
      end
    end
  end
end
