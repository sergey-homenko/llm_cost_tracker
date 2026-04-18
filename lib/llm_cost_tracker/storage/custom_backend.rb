# frozen_string_literal: true

module LlmCostTracker
  module Storage
    module CustomBackend
      class << self
        def save(event, config:)
          result = config.custom_storage&.call(event)
          return false if result == false

          event
        end
      end
    end
  end
end
