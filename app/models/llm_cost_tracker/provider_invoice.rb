# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class ProviderInvoice < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_provider_invoices"
  end
end
