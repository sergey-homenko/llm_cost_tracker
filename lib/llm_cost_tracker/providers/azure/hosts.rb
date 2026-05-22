# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Azure
      module Hosts
        OPENAI_HOST_PATTERN = /\A[a-z0-9][a-z0-9-]*\.(?:openai\.azure\.com|services\.ai\.azure\.com)\z/i
        def self.openai?(host)
          host.to_s.match?(OPENAI_HOST_PATTERN)
        end
      end
    end
  end
end
