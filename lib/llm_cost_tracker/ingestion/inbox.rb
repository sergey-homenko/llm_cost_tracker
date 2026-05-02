# frozen_string_literal: true

require "json"
require "time"

require_relative "../event"
require_relative "../usage_capture"
require_relative "../pricing"
require_relative "../billing/cost_status"
require_relative "../billing/service_charge"

module LlmCostTracker
  module Ingestion
    class Inbox
      PAYLOAD_SCHEMA_VERSION = 2
      SUPPORTED_PAYLOAD_SCHEMA_VERSIONS = [0, 1, 2].freeze

      class << self
        def save(event)
          insert_row(row_for(event))
          Ingestion::Worker.ensure_started
          event
        end

        def event_from_row(row)
          payload = JSON.parse(row.payload, symbolize_names: true)
          schema_version = payload.fetch(:schema_version, 0)
          unless SUPPORTED_PAYLOAD_SCHEMA_VERSIONS.include?(schema_version)
            raise LlmCostTracker::Error, "unsupported ledger inbox payload schema version #{schema_version.inspect}"
          end

          LlmCostTracker::Event.new(**event_attributes_from(payload))
        end

        private

        def event_attributes_from(payload)
          cost = payload[:cost] && Pricing.stored_cost_attributes(payload[:cost])
          token_usage_attributes = payload[:token_usage] || payload
          token_usage = TokenUsage.build(**token_usage_attributes.slice(*TokenUsage.members))
          service_charges = service_charges_from(payload)
          usage_source = payload[:usage_source]&.to_sym

          {
            event_id: payload.fetch(:event_id),
            provider: payload.fetch(:provider),
            model: payload.fetch(:model),
            token_usage: token_usage,
            pricing_mode: Pricing.normalize_mode(payload[:pricing_mode]),
            cost: cost,
            tags: payload.fetch(:tags),
            latency_ms: payload[:latency_ms],
            stream: payload.fetch(:stream),
            usage_source: usage_source,
            provider_response_id: payload[:provider_response_id],
            tracked_at: Time.iso8601(payload.fetch(:tracked_at)),
            cost_status: cost_status_for(
              payload: payload,
              token_usage: token_usage,
              cost: cost,
              service_charges: service_charges,
              usage_source: usage_source
            ),
            pricing_snapshot: payload[:pricing_snapshot],
            service_charges: service_charges
          }
        end

        def cost_status_for(payload:, token_usage:, cost:, service_charges:, usage_source:)
          payload[:cost_status] || Billing::CostStatus.call(
            token_usage: token_usage,
            usage_source: usage_source,
            token_cost: cost,
            service_charges: service_charges,
            total_cost: cost&.fetch(:total_cost, nil)
          )
        end

        def service_charges_from(payload)
          charges = Array(payload[:service_charges]).map do |charge|
            charge.merge(
              component: charge[:component]&.to_sym,
              unit: charge[:unit]&.to_sym,
              pricing_basis: charge[:pricing_basis]&.to_sym,
              price_source: charge[:price_source]&.to_sym
            )
          end

          Billing::ServiceCharge.build_many(charges)
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
          table = connection.quote_table_name(InboxRow.table_name)

          connection.execute("INSERT INTO #{table} (#{quoted_columns}) VALUES (#{quoted_values})")
        end
      end
    end
  end
end
