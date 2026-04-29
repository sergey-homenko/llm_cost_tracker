# frozen_string_literal: true

require "time"

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
        return unless active_record_storage? && llm_api_calls_table?

        missing = missing_parts
        if missing.empty?
          quarantined = quarantined_count
          if quarantined.positive?
            return check_class.new(:warn, "durable ingestion", "#{quarantined} inbox events quarantined after retries")
          end

          pending = pending_snapshot
          if stale_pending?(pending)
            return check_class.new(
              :warn,
              "durable ingestion",
              "#{pending.fetch(:count)} inbox events pending; oldest pending age #{pending_age(pending).round}s"
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
        [
          column_names("llm_api_calls").include?("event_id") ? nil : "llm_api_calls.event_id",
          table_exists?("llm_cost_tracker_inbox_events") ? nil : "llm_cost_tracker_inbox_events",
          table_exists?("llm_cost_tracker_ingestor_leases") ? nil : "llm_cost_tracker_ingestor_leases"
        ].compact
      end

      def active_record_storage? = LlmCostTracker.configuration.storage_backend == :active_record

      def llm_api_calls_table? = table_exists?("llm_api_calls")

      def table_exists?(name)
        LlmCostTracker::LlmApiCall.connection.data_source_exists?(name)
      rescue StandardError
        false
      end

      def column_names(table) = LlmCostTracker::LlmApiCall.connection.columns(table).map(&:name)

      def quarantined_count
        return 0 unless table_exists?("llm_cost_tracker_inbox_events")

        LlmCostTracker::LlmApiCall.connection.select_value(quarantined_sql).to_i
      rescue StandardError
        0
      end

      def quarantined_sql
        table = LlmCostTracker::LlmApiCall.connection.quote_table_name("llm_cost_tracker_inbox_events")
        "SELECT COUNT(*) FROM #{table} WHERE attempts >= #{max_attempts}"
      end

      def pending_snapshot
        row = LlmCostTracker::LlmApiCall.connection.select_one(pending_sql) || {}
        {
          count: row.fetch("pending_count").to_i,
          oldest_at: row["oldest_created_at"] && Time.parse(row.fetch("oldest_created_at").to_s).utc
        }
      rescue StandardError
        { count: 0, oldest_at: nil }
      end

      def pending_sql
        table = LlmCostTracker::LlmApiCall.connection.quote_table_name("llm_cost_tracker_inbox_events")
        "SELECT COUNT(*) AS pending_count, MIN(created_at) AS oldest_created_at " \
          "FROM #{table} WHERE attempts < #{max_attempts}"
      end

      def stale_pending?(pending)
        pending.fetch(:count).positive? &&
          pending.fetch(:oldest_at) &&
          pending_age(pending) >= PENDING_AGE_WARNING_SECONDS
      end

      def pending_age(pending) = Time.now.utc - pending.fetch(:oldest_at)

      def max_attempts
        if defined?(LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS)
          LlmCostTracker::Storage::ActiveRecordInbox::MAX_ATTEMPTS
        else
          5
        end
      end
    end
  end
end
