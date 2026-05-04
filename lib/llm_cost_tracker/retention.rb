# frozen_string_literal: true

module LlmCostTracker
  module Retention
    DEFAULT_BATCH_SIZE = 5_000

    class << self
      def prune(older_than:, batch_size: DEFAULT_BATCH_SIZE, now: Time.now.utc)
        batch_size = batch_size.to_i
        raise ArgumentError, "batch_size must be positive: #{batch_size.inspect}" unless batch_size.positive?

        cutoff = resolve_cutoff(older_than, now)
        require_relative "ledger"

        deleted = 0
        loop do
          batch = prune_batch(cutoff, batch_size)
          deleted += batch
          break if batch < batch_size
        end
        deleted
      end

      private

      def resolve_cutoff(older_than, now)
        cutoff = case older_than
                 when Time, DateTime then older_than.utc
                 when ActiveSupport::Duration then duration_cutoff(older_than, now)
                 when Integer then integer_day_cutoff(older_than, now)
                 else
                   raise ArgumentError, "older_than must be a Duration, Time, or Integer days: #{older_than.inspect}"
                 end
        raise ArgumentError, "older_than cutoff must be before now: #{cutoff.inspect}" unless cutoff < now

        cutoff
      end

      def duration_cutoff(duration, now)
        raise ArgumentError, "older_than duration must be positive: #{duration.inspect}" unless duration.to_i.positive?

        now - duration
      end

      def integer_day_cutoff(days, now)
        raise ArgumentError, "older_than days must be positive: #{days.inspect}" unless days.positive?

        now - (days * 86_400)
      end

      def prune_batch(cutoff, batch_size)
        LlmCostTracker::Call.transaction do
          rows = LlmCostTracker::Call
                 .where(tracked_at: ...cutoff)
                 .order(:id)
                 .limit(batch_size)
                 .lock
                 .pluck(:id, :tracked_at, :total_cost)
          next 0 if rows.empty?

          LlmCostTracker::ServiceCharge.where(llm_cost_tracker_call_id: rows.map(&:first)).delete_all
          deleted = LlmCostTracker::Call.where(id: rows.map(&:first)).delete_all
          LlmCostTracker::Ledger::Rollups.decrement!(rows) if deleted.positive?
          deleted
        end
      end
    end
  end
end
