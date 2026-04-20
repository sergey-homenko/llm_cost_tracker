# frozen_string_literal: true

module LlmCostTracker
  module Retention
    DEFAULT_BATCH_SIZE = 5_000

    class << self
      def prune(older_than:, batch_size: DEFAULT_BATCH_SIZE, now: Time.now.utc)
        cutoff = resolve_cutoff(older_than, now)
        require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

        deleted = 0
        loop do
          batch = LlmCostTracker::LlmApiCall.where(tracked_at: ...cutoff).limit(batch_size).delete_all
          deleted += batch
          break if batch < batch_size
        end
        deleted
      end

      private

      def resolve_cutoff(older_than, now)
        case older_than
        when Time, DateTime then older_than.utc
        when ActiveSupport::Duration then now - older_than
        when Integer then now - (older_than * 86_400)
        else
          raise ArgumentError, "older_than must be a Duration, Time, or Integer days: #{older_than.inspect}"
        end
      end
    end
  end
end
