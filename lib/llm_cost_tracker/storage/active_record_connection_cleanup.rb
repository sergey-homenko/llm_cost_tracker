# frozen_string_literal: true

module LlmCostTracker
  module Storage
    module ActiveRecordConnectionCleanup
      def self.release!
        ActiveRecord::Base.connection_handler.clear_active_connections!
      rescue StandardError
        nil
      end
    end
  end
end
