# frozen_string_literal: true

require_relative "check"
require_relative "probe"
require_relative "../ingestion"

module LlmCostTracker
  class Doctor
    class IngestionCheck
      PENDING_AGE_WARNING_SECONDS = 60

      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")

        missing = missing_parts
        if missing.empty?
          inbox = inbox_snapshot
          quarantined = inbox.try(:quarantined_count).to_i
          if quarantined.positive?
            return Check.new(:warn, "durable ingestion", "#{quarantined} inbox entries quarantined after retries")
          end

          pending_count = inbox.try(:pending_count).to_i
          oldest_pending_at = inbox.try(:oldest_pending_at)&.to_time&.utc
          pending_age = oldest_pending_at && (Time.now.utc - oldest_pending_at)
          if pending_count.positive? && pending_age && pending_age >= PENDING_AGE_WARNING_SECONDS
            return Check.new(
              :warn,
              "durable ingestion",
              "#{pending_count} inbox entries pending; oldest pending age #{pending_age.round}s"
            )
          end

          return Check.new(:ok, "durable ingestion", "inbox and ingestion lease tables available")
        end

        Check.new(
          :error,
          "durable ingestion",
          "missing #{missing.join(', ')}; see docs/upgrading.md for the recovery steps"
        )
      end

      private

      def missing_parts
        [
          LlmCostTracker::Ingestion::InboxEntry.table_name,
          LlmCostTracker::Ingestion::Lease.table_name
        ].reject { |table| Probe.table_exists?(table) }
      end

      def inbox_snapshot
        max_attempts = LlmCostTracker::Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE
        LlmCostTracker::Ingestion::InboxEntry
          .select(
            "COALESCE(SUM(CASE WHEN attempts >= #{max_attempts} " \
            "THEN 1 ELSE 0 END), 0) AS quarantined_count, " \
            "COALESCE(SUM(CASE WHEN attempts < #{max_attempts} " \
            "THEN 1 ELSE 0 END), 0) AS pending_count, " \
            "MIN(CASE WHEN attempts < #{max_attempts} " \
            "THEN created_at ELSE NULL END) AS oldest_pending_at"
          )
          .take
      rescue StandardError
        nil
      end
    end
  end
end
