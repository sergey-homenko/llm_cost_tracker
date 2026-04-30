# frozen_string_literal: true

require_relative "../ingestion"

module LlmCostTracker
  class Doctor
    class IngestionCheck
      PENDING_AGE_WARNING_SECONDS = 60

      def self.call(check_class)
        new(check_class).call
      end

      def initialize(check_class)
        @check_class = check_class
      end

      def call
        return unless table_exists?("llm_api_calls")

        missing = missing_parts
        if missing.empty?
          quarantined = quarantined_count
          if quarantined.positive?
            return check_class.new(:warn, "durable ingestion", "#{quarantined} inbox events quarantined after retries")
          end

          pending = pending_snapshot
          pending_count = pending.try(:pending_count).to_i
          oldest_pending_at = pending.try(:oldest_created_at)&.to_time&.utc
          pending_age = oldest_pending_at && (Time.now.utc - oldest_pending_at)
          if pending_count.positive? && pending_age && pending_age >= PENDING_AGE_WARNING_SECONDS
            return check_class.new(
              :warn,
              "durable ingestion",
              "#{pending_count} inbox events pending; oldest pending age #{pending_age.round}s"
            )
          end

          return check_class.new(:ok, "durable ingestion", "inbox and ingestor lease tables available")
        end

        check_class.new(
          :error,
          "durable ingestion",
          "missing #{missing.join(', ')}; run bin/rails generate llm_cost_tracker:add_ingestion && bin/rails db:migrate"
        )
      end

      private

      attr_reader :check_class

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

      def quarantined_count
        return 0 unless table_exists?("llm_cost_tracker_inbox_events")

        LlmCostTracker::Ingestion::Event
          .where("attempts >= ?", LlmCostTracker::Ingestion::Inbox::MAX_ATTEMPTS)
          .count
      rescue StandardError
        0
      end

      def pending_snapshot
        LlmCostTracker::Ingestion::Event
          .where("attempts < ?", LlmCostTracker::Ingestion::Inbox::MAX_ATTEMPTS)
          .select("COUNT(*) AS pending_count, MIN(created_at) AS oldest_created_at")
          .take
      rescue StandardError
        nil
      end
    end
  end
end
