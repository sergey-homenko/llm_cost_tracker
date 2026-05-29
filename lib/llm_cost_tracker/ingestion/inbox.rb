# frozen_string_literal: true

require "json"
require "time"

require_relative "../event"
require_relative "../pricing"

module LlmCostTracker
  module Ingestion
    class Inbox
      PAYLOAD_SCHEMA_VERSION = 2

      class << self
        def save(event)
          insert_row(row_for(event))
        end

        def event_from_row(row)
          payload = JSON.parse(row.payload, symbolize_names: true)
          schema_version = payload[:schema_version]
          unless schema_version == PAYLOAD_SCHEMA_VERSION
            raise LlmCostTracker::Error, "unsupported ledger inbox payload schema version #{schema_version.inspect}"
          end

          LlmCostTracker::Event.new(**event_attributes_from(payload))
        end

        private

        def event_attributes_from(payload)
          cost = payload[:cost] && Billing::Cost.from_h(payload[:cost])
          token_usage = TokenUsage.build(**payload.fetch(:token_usage).slice(*TokenUsage.members))

          {
            event_id: payload.fetch(:event_id),
            provider: payload.fetch(:provider),
            model: payload.fetch(:model),
            token_usage: token_usage,
            pricing_mode: Pricing::Mode.normalize(payload[:pricing_mode]),
            cost: cost,
            tags: payload.fetch(:tags),
            latency_ms: payload[:latency_ms],
            stream: payload.fetch(:stream),
            usage_source: payload[:usage_source],
            provider_response_id: payload[:provider_response_id],
            provider_project_id: payload[:provider_project_id],
            provider_api_key_id: payload[:provider_api_key_id],
            provider_workspace_id: payload[:provider_workspace_id],
            tracked_at: Time.iso8601(payload.fetch(:tracked_at)),
            cost_status: payload.fetch(:cost_status),
            pricing_snapshot: payload[:pricing_snapshot],
            line_items: (payload[:line_items] || []).map { |attrs| Billing::LineItem.build(attrs) }
          }
        end

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
          Pool.with_connection { |connection| execute_insert(connection, row) }
        rescue ActiveRecord::ConnectionTimeoutError => e
          raise LlmCostTracker::Error,
                "ledger inbox could not checkout a database connection: #{e.message}"
        end

        def execute_insert(connection, row)
          columns = row.keys
          quoted_columns = columns.map { |column| connection.quote_column_name(column) }.join(", ")
          quoted_values = columns.map { |column| connection.quote(row.fetch(column)) }.join(", ")
          table = connection.quote_table_name(InboxEntry.table_name)
          connection.execute("INSERT INTO #{table} (#{quoted_columns}) VALUES (#{quoted_values})")
        end
      end
    end
  end
end
