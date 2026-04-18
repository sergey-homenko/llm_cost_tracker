# frozen_string_literal: true

require_relative "../errors"
require_relative "log_backend"
require_relative "active_record_backend"
require_relative "custom_backend"

module LlmCostTracker
  module Storage
    module Backends
      MAP = {
        log: LogBackend,
        active_record: ActiveRecordBackend,
        custom: CustomBackend
      }.freeze

      class << self
        def fetch(name)
          MAP.fetch(name.to_sym)
        rescue KeyError
          raise Error, "Unknown storage_backend: #{name.inspect}. Use one of: #{MAP.keys.join(', ')}"
        end
      end
    end
  end
end
