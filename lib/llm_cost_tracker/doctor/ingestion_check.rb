# frozen_string_literal: true

require_relative "../check"
require_relative "probe"
require_relative "../ingestion"

module LlmCostTracker
  class Doctor
    class IngestionCheck
      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")
        return inline_check unless LlmCostTracker::Ingestion.async?

        problems = missing_parts + drifted_parts
        return async_ok if problems.empty?

        Check.new(
          :error,
          "async ingestion",
          "#{problems.join('; ')}; see docs/upgrading.md for the recovery steps"
        )
      end

      private

      def async_ok
        Check.new(:ok, "async ingestion", "inbox and ingestion lease tables are on the current schema")
      end

      def inline_check
        leftovers = inline_leftover_tables
        if leftovers.empty?
          return Check.new(:ok,
                           "inline ingestion",
                           "config.ingestion.mode = :inline; events write directly to the ledger")
        end

        Check.new(
          :warn,
          "inline ingestion",
          "config.ingestion.mode = :inline but found unused async ingestion tables: #{leftovers.join(', ')}. " \
          "Set config.ingestion.mode = :async to keep the inbox path or drop the tables."
        )
      end

      def inline_leftover_tables
        async_tables.select { |table| Probe.table_exists?(table) }
      end

      def missing_parts
        async_tables.reject { |table| Probe.table_exists?(table) }.map { |table| "missing #{table}" }
      end

      def drifted_parts
        LlmCostTracker::Ledger::Schema::ASYNC_SCHEMAS.filter_map do |schema, table|
          next unless Probe.table_exists?(table)

          errors = schema.current_schema_errors
          "#{table} #{errors.join(', ')}" unless errors.empty?
        end
      end

      def async_tables
        [
          LlmCostTracker::Ingestion::InboxEntry.table_name,
          LlmCostTracker::Ingestion::Lease.table_name
        ]
      end
    end
  end
end
