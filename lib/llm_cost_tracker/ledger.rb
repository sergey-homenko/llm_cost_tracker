# frozen_string_literal: true

require_relative "ledger/schema/adapter"
require_relative "ledger/schema/calls"
require_relative "ledger/schema/call_rollups"
require_relative "ledger/schema/call_line_items"
require_relative "ledger/schema/call_tags"
require_relative "ledger/schema/ingestion/inbox_entries"
require_relative "ledger/schema/ingestion/leases"
require_relative "ledger/tags/query"
require_relative "ledger/tags/sql"
require_relative "ledger/period"
require_relative "ledger/rollups/upsert_sql"
require_relative "ledger/rollups"
require_relative "ledger/store"
require_relative "ledger/period/totals"

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
