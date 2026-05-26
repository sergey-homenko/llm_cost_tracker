# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Ledger
    module Schema
      module Ingestion
        module Leases
          extend Base

          columns :name, :locked_by, :locked_until, :created_at, :updated_at
        end
      end
    end
  end
end
