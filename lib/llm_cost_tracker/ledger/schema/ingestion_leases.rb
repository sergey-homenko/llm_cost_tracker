# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module IngestionLeases
        extend Base

        REQUIRED_COLUMNS = %w[name locked_by locked_until created_at updated_at].freeze

        REQUIRED_INDEXES = [
          { columns: :name, unique: true }
        ].freeze

        def self.model = LlmCostTracker::Ingestion::Lease
      end
    end
  end
end
