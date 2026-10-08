# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module CallOrder
      NATURAL_DIRECTIONS = {
        "tracked_at" => "desc",
        "provider" => "asc",
        "model" => "asc",
        "input" => "desc",
        "output" => "desc",
        "cost" => "desc",
        "latency" => "desc"
      }.freeze
      NEWEST_FIRST = { tracked_at: :desc, id: :desc }.freeze
      COST_NULLS_LAST = Arel.sql("CASE WHEN total_cost IS NULL THEN 1 ELSE 0 END ASC")
      LATENCY_NULLS_LAST = Arel.sql("CASE WHEN latency_ms IS NULL THEN 1 ELSE 0 END ASC")
      ORDERS = {
        "tracked_at" => ->(dir) { [{ tracked_at: dir, id: dir }] },
        "provider" => ->(dir) { [{ provider: dir, model: :asc, **NEWEST_FIRST }] },
        "model" => ->(dir) { [{ model: dir, **NEWEST_FIRST }] },
        "input" => ->(dir) { [{ input_tokens: dir, **NEWEST_FIRST }] },
        "output" => ->(dir) { [{ output_tokens: dir, **NEWEST_FIRST }] },
        "cost" => ->(dir) { [COST_NULLS_LAST, { total_cost: dir, **NEWEST_FIRST }] },
        "latency" => ->(dir) { [LATENCY_NULLS_LAST, { latency_ms: dir, **NEWEST_FIRST }] }
      }.freeze

      def self.call(scope, sort:, direction:)
        choice = Sort.resolve(
          sort, direction.to_s.downcase, natural_directions: NATURAL_DIRECTIONS, fallback: "tracked_at"
        )
        scope.order(*ORDERS.fetch(choice.column).call(choice.direction.to_sym))
      end
    end
  end
end
