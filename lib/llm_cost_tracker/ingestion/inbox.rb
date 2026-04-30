# frozen_string_literal: true

require "json"
require "time"

require_relative "../event"
require_relative "event"

module LlmCostTracker
  module Ingestion
    class Inbox
      PAYLOAD_SCHEMA_VERSION = 1

      class << self
        def save(event)
          insert_row(row_for(event))
          Ingestion::Worker.ensure_started
          event
        end

        def event_from_row(row)
          payload = JSON.parse(row.payload)
          schema_version = payload.fetch("schema_version", 0)
          unless [0, PAYLOAD_SCHEMA_VERSION].include?(schema_version)
            raise LlmCostTracker::Error, "unsupported ledger inbox payload schema version #{schema_version.inspect}"
          end

          cost = payload["cost"] && TokenUsage.stored_cost_attributes(payload["cost"])
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
            total_cost: event.total_cost,
            tracked_at: event.tracked_at,
            payload: JSON.generate(payload_for(event)),
            attempts: 0,
            created_at: now,
            updated_at: now
          }
        end

        def payload_for(event)
          event.to_h.merge(
            schema_version: PAYLOAD_SCHEMA_VERSION,
            event_id: event.event_id,
            provider: event.provider,
            model: event.model,
            tracked_at: event.tracked_at.iso8601(6)
          )
        end

        def insert_row(row)
          connection = LlmCostTracker::Ledger::Call.connection
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
          pool = LlmCostTracker::Ledger::Call.connection_pool
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
          table = connection.quote_table_name(Event.table_name)

          connection.execute("INSERT INTO #{table} (#{quoted_columns}) VALUES (#{quoted_values})")
        end
      end
    end
  end
end
