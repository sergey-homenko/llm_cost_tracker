# frozen_string_literal: true

require "json"
require "time"
require "active_support/core_ext/hash/keys"

require_relative "../event"
require_relative "../pricing"

module LlmCostTracker
  module Ingestion
    module Inbox
      PAYLOAD_SCHEMA_VERSION = 2
      OPTIONAL_FIELDS = %i[
        latency_ms usage_source provider_response_id provider_project_id provider_api_key_id provider_workspace_id
      ].freeze

      class << self
        def save(event)
          insert_row(row_for(event))
        end

        def event_from_row(row)
          payload = JSON.parse(row.payload, symbolize_names: true, allow_duplicate_key: true)
          schema_version = payload[:schema_version]
          unless schema_version == PAYLOAD_SCHEMA_VERSION
            raise LlmCostTracker::Error, "unsupported ledger inbox payload schema version #{schema_version.inspect}"
          end

          LlmCostTracker::Event.new(**event_attributes_from(payload))
        end

        private

        def event_attributes_from(payload)
          cost = cost_from(payload)
          token_usage = token_usage_from(payload)
          {
            event_id: payload.fetch(:event_id),
            provider: payload.fetch(:provider),
            model: payload.fetch(:model),
            token_usage: token_usage,
            pricing_mode: Pricing::Mode.normalize(payload[:pricing_mode]),
            cost: cost,
            tags: payload.fetch(:tags),
            stream: payload.fetch(:stream),
            **OPTIONAL_FIELDS.to_h { |field| [field, payload[field]] },
            tracked_at: Time.iso8601(payload.fetch(:tracked_at)),
            cost_status: payload.fetch(:cost_status),
            pricing_snapshot: payload[:pricing_snapshot]&.deep_stringify_keys,
            line_items: line_items_from(payload)
          }
        end

        def cost_from(payload)
          payload[:cost] && Charges::Cost.from_h(payload[:cost])
        end

        def token_usage_from(payload)
          Usage::TokenUsage.build(**payload.fetch(:token_usage).slice(*Usage::TokenUsage.members))
        end

        def line_items_from(payload)
          (payload[:line_items] || []).map { |attrs| Charges::LineItem.build(attrs) }
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
          event.to_h.merge(schema_version: PAYLOAD_SCHEMA_VERSION, tracked_at: event.tracked_at.iso8601(6))
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
