# frozen_string_literal: true

module LlmCostTracker
  Cost = Data.define(
    :input_cost,
    :cache_read_input_cost,
    :cache_write_input_cost,
    :output_cost,
    :total_cost,
    :currency
  )
end
