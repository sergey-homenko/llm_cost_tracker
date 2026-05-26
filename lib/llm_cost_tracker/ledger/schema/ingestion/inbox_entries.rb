# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Ledger
    module Schema
      module Ingestion
        module InboxEntries
          extend Base

          columns :event_id, :total_cost, :tracked_at, :payload, :locked_at, :locked_by,
                  :attempts, :last_error, :created_at, :updated_at
        end
      end
    end
  end
end
