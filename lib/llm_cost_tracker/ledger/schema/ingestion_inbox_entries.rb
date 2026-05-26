# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module IngestionInboxEntries
        extend Base

        REQUIRED_COLUMNS = %w[
          event_id
          total_cost
          tracked_at
          payload
          locked_at
          locked_by
          attempts
          last_error
          created_at
          updated_at
        ].freeze

        REQUIRED_INDEXES = [
          { columns: :event_id, unique: true }
        ].freeze

        def self.model = LlmCostTracker::Ingestion::InboxEntry
      end
    end
  end
end
