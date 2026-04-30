# frozen_string_literal: true

require "time"

require_relative "../ledger"

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
          pending_age = pending.fetch(:oldest_at) && (Time.now.utc - pending.fetch(:oldest_at))
          if pending.fetch(:count).positive? && pending_age && pending_age >= PENDING_AGE_WARNING_SECONDS
            return check_class.new(
              :warn,
              "durable ingestion",
              "#{pending.fetch(:count)} inbox events pending; oldest pending age #{pending_age.round}s"
            )
          end

          return check_class.new(:ok, "durable ingestion", "inbox and ingestor lease tables available")
        end

        check_class.new(
          :warn,
          "durable ingestion",
          "missing #{missing.join(', ')}; run bin/rails generate llm_cost_tracker:add_ingestion && bin/rails db:migrate"
        )
      end

      private

      attr_reader :check_class

      def missing_parts
        columns = LlmCostTracker::Ledger::Call.connection.columns("llm_api_calls").map(&:name)
        [
          columns.include?("event_id") ? nil : "llm_api_calls.event_id",
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

        LlmCostTracker::Ledger::Call.connection.select_value(quarantined_sql).to_i
      rescue StandardError
        0
      end

      def quarantined_sql
        table = LlmCostTracker::Ledger::Call.connection.quote_table_name("llm_cost_tracker_inbox_events")
        "SELECT COUNT(*) FROM #{table} WHERE attempts >= #{LlmCostTracker::Ledger::Ingestion::Inbox::MAX_ATTEMPTS}"
      end

      def pending_snapshot
        row = LlmCostTracker::Ledger::Call.connection.select_one(pending_sql) || {}
        {
          count: row.fetch("pending_count").to_i,
          oldest_at: row["oldest_created_at"] && Time.parse(row.fetch("oldest_created_at").to_s).utc
        }
      rescue StandardError
        { count: 0, oldest_at: nil }
      end

      def pending_sql
        table = LlmCostTracker::Ledger::Call.connection.quote_table_name("llm_cost_tracker_inbox_events")
        "SELECT COUNT(*) AS pending_count, MIN(created_at) AS oldest_created_at " \
          "FROM #{table} WHERE attempts < #{LlmCostTracker::Ledger::Ingestion::Inbox::MAX_ATTEMPTS}"
      end
    end
  end
end
