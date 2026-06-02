# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Ledger
    module Schema
      module CallLineItems
        extend Base

        columns :llm_cost_tracker_call_id,
                :position,
                :kind,
                :direction,
                :modality,
                :cache_state,
                :quantity,
                :unit,
                :rate_amount,
                :rate_quantity,
                :cost,
                :currency,
                :cost_status,
                :pricing_basis,
                :price_key,
                :price_source,
                :price_source_version,
                :provider_field,
                :provider_item_id,
                :details,
                :created_at
      end
    end
  end
end
