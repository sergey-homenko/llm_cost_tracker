# frozen_string_literal: true

module LlmCostTracker
  module Storage
    module ActiveRecordBackend
      class << self
        def save(event, **_options)
          require_relative "../llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
          require_relative "active_record_store" unless defined?(LlmCostTracker::Storage::ActiveRecordStore)

          ActiveRecordStore.save(event)
          event
        rescue LoadError => e
          raise Error, "ActiveRecord storage requires the active_record gem: #{e.message}"
        end
      end
    end
  end
end
