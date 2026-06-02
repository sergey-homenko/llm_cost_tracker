# frozen_string_literal: true

require_relative "schema/adapter"
require_relative "schema/calls"
require_relative "schema/call_rollups"
require_relative "schema/call_line_items"
require_relative "schema/call_tags"
require_relative "schema/ingestion/inbox_entries"
require_relative "schema/ingestion/leases"

module LlmCostTracker
  module Ledger
    module Schema
      CORE_SCHEMAS = [
        [Calls, "llm_cost_tracker_calls"],
        [CallLineItems, "llm_cost_tracker_call_line_items"],
        [CallTags, "llm_cost_tracker_call_tags"]
      ].freeze
      CACHE_ROLLUPS_SCHEMA = [CallRollups, "llm_cost_tracker_call_rollups"].freeze
      ASYNC_SCHEMAS = [
        [Ingestion::InboxEntries, "llm_cost_tracker_ingestion_inbox_entries"],
        [Ingestion::Leases, "llm_cost_tracker_ingestion_leases"]
      ].freeze
    end
  end
end
