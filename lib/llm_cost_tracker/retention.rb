# frozen_string_literal: true

module LlmCostTracker
  module Retention
    DEFAULT_BATCH_SIZE = 5_000

    class << self
      def prune(older_than:, batch_size: DEFAULT_BATCH_SIZE, now: Time.now.utc)
        batch_size = normalized_batch_size(batch_size)
        cutoff = resolve_cutoff(older_than, now)
        require_relative "storage/active_record_backend"

        Storage::ActiveRecordBackend.prune(cutoff: cutoff, batch_size: batch_size)
      end

      private

      def normalized_batch_size(value)
        value = value.to_i
        raise ArgumentError, "batch_size must be positive: #{value.inspect}" unless value.positive?

        value
      end

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
    end
  end
end
