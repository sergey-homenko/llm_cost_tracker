# frozen_string_literal: true

require "json"
require "time"

require_relative "cost"
require_relative "event"
require_relative "inbox_event"
require_relative "periods"

module LlmCostTracker
  class Inbox
    TABLE_NAME = "llm_cost_tracker_inbox_events"
    LEASE_TABLE_NAME = "llm_cost_tracker_ingestor_leases"
    MAX_ATTEMPTS = 5

    class << self
      def reset!
        remove_instance_variable(:@enabled) if instance_variable_defined?(:@enabled)
      end

      def enabled?
        return @enabled unless @enabled.nil?

        model = LlmCostTracker::LlmApiCall
        @enabled = model.columns_hash.key?("event_id") &&
                   model.connection.data_source_exists?(TABLE_NAME) &&
                   model.connection.data_source_exists?(LEASE_TABLE_NAME)
      rescue StandardError
        @enabled = false
      end

      def save(event)
        insert_row(row_for(event))
        Ingestor.ensure_started
        event
      end

      def pending_period_totals(periods, time:)
        return periods.to_h { |period| [period, 0.0] } unless enabled?

        periods.to_h do |period|
          [period, pending_period_total(period, time)]
        end
      end

      def event_from_row(row)
        payload = JSON.parse(row.payload)
        cost = payload["cost"] && LlmCostTracker::Cost.from_hash(payload["cost"])
        token_usage = payload["token_usage"] || payload

        LlmCostTracker::Event.new(
          event_id: payload.fetch("event_id"),
          provider: payload.fetch("provider"),
          model: payload.fetch("model"),
          token_usage: TokenUsage.from_hash(token_usage),
          pricing_mode: payload["pricing_mode"],
          cost: cost,
          tags: payload.fetch("tags"),
          latency_ms: payload["latency_ms"],
          stream: payload.fetch("stream"),
          usage_source: payload["usage_source"],
          provider_response_id: payload["provider_response_id"],
          tracked_at: Time.iso8601(payload.fetch("tracked_at"))
        )
      end

      private

      def row_for(event)
        now = Time.now.utc
        {
          event_id: event.event_id,
          total_cost: event.cost&.total_cost,
          tracked_at: event.tracked_at,
          payload: JSON.generate(payload_for(event)),
          attempts: 0,
          created_at: now,
          updated_at: now
        }
      end

      def payload_for(event)
        event.to_h.merge(
          event_id: event.event_id,
          provider: event.provider,
          model: event.model,
          tracked_at: event.tracked_at.iso8601(6)
        )
      end

      def insert_row(row)
        connection = LlmCostTracker::LlmApiCall.connection
        if connection.transaction_open?
          insert_with_separate_connection(row)
        else
          execute_insert(connection, row)
        end
      rescue ActiveRecord::ConnectionTimeoutError => e
        raise LlmCostTracker::Error,
              "ledger inbox could not checkout a separate database connection: #{e.message}"
      end

      def insert_with_separate_connection(row)
        pool = LlmCostTracker::LlmApiCall.connection_pool
        connection = pool.checkout
        begin
          connection.transaction(requires_new: true) { execute_insert(connection, row) }
        ensure
          pool.checkin(connection)
        end
      end

      def execute_insert(connection, row)
        columns = row.keys
        quoted_columns = columns.map { |column| connection.quote_column_name(column) }.join(", ")
        quoted_values = columns.map { |column| connection.quote(row.fetch(column)) }.join(", ")
        table = connection.quote_table_name(TABLE_NAME)

        connection.execute("INSERT INTO #{table} (#{quoted_columns}) VALUES (#{quoted_values})")
      end

      def pending_period_total(period, time)
        LlmCostTracker::InboxEvent
          .where("attempts < ?", MAX_ATTEMPTS)
          .where(tracked_at: period_range(period, time))
          .sum(:total_cost)
          .to_f
      end

      def period_range(period, time)
        utc_time = time.to_time.utc
        Periods.range_start(period, utc_time)..utc_time
      end
    end
  end
end
