# frozen_string_literal: true

require_relative "check"
require_relative "../ingestion"

module LlmCostTracker
  class Doctor
    class IngestionCheck
      PENDING_AGE_WARNING_SECONDS = 60

      def call
        return unless table_exists?("llm_api_calls")

        missing = missing_parts
        if missing.empty?
          inbox = inbox_snapshot
          quarantined = inbox.try(:quarantined_count).to_i
          if quarantined.positive?
            return Check.new(:warn, "durable ingestion", "#{quarantined} inbox events quarantined after retries")
          end

          pending_count = inbox.try(:pending_count).to_i
          oldest_pending_at = inbox.try(:oldest_pending_at)&.to_time&.utc
          pending_age = oldest_pending_at && (Time.now.utc - oldest_pending_at)
          if pending_count.positive? && pending_age && pending_age >= PENDING_AGE_WARNING_SECONDS
            return Check.new(
              :warn,
              "durable ingestion",
              "#{pending_count} inbox events pending; oldest pending age #{pending_age.round}s"
            )
          end

          return Check.new(:ok, "durable ingestion", "inbox and ingestor lease tables available")
        end

        Check.new(
          :error,
          "durable ingestion",
          "missing #{missing.join(', ')}; run bin/rails generate llm_cost_tracker:add_ingestion && bin/rails db:migrate"
        )
      end

      private

      def missing_parts
        [
          table_exists?("llm_cost_tracker_inbox_events") ? nil : "llm_cost_tracker_inbox_events",
          table_exists?("llm_cost_tracker_ingestor_leases") ? nil : "llm_cost_tracker_ingestor_leases"
        ].compact
      end

      def table_exists?(name)
        LlmCostTracker::Ledger::Call.connection.data_source_exists?(name)
      rescue StandardError
        false
      end

      def inbox_snapshot
        LlmCostTracker::Ingestion::Event
          .select(
            "COALESCE(SUM(CASE WHEN attempts >= #{LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS} " \
            "THEN 1 ELSE 0 END), 0) AS quarantined_count, " \
            "COALESCE(SUM(CASE WHEN attempts < #{LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS} " \
            "THEN 1 ELSE 0 END), 0) AS pending_count, " \
            "MIN(CASE WHEN attempts < #{LlmCostTracker::Ingestion::Event::MAX_ATTEMPTS} " \
            "THEN created_at ELSE NULL END) AS oldest_pending_at"
          )
          .take
      rescue StandardError
        nil
      end
    end
  end
end
