# frozen_string_literal: true

module LlmCostTracker
  Cost = Data.define(
    :input_cost,
    :cached_input_cost,
    :cache_read_input_cost,
    :cache_creation_input_cost,
    :output_cost,
    :total_cost,
    :currency
  )
end
