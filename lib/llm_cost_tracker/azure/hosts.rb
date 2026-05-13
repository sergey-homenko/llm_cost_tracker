# frozen_string_literal: true

module LlmCostTracker
  module Azure
    module Hosts
      OPENAI_HOST_PATTERN = /\A[a-z0-9][a-z0-9-]*\.openai\.azure\.com\z/i

      module_function

      def openai?(host)
        host.to_s.match?(OPENAI_HOST_PATTERN)
      end
    end
  end
end
