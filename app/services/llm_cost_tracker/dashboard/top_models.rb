# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    TopModel = Data.define(
      :provider,
      :model,
      :calls,
      :total_cost,
      :average_cost_per_call,
      :input_tokens,
      :output_tokens,
      :average_latency_ms
    )

    class TopModels
      DEFAULT_LIMIT = 5
      SORT_OPTIONS = {
        "cost"     => "total_cost_sum DESC",
        "calls"    => "calls_count DESC",
        "avg_cost" => "total_cost_sum / calls_count DESC",
        "latency"  => "average_latency DESC NULLS LAST"
      }.freeze
      DEFAULT_SORT = "cost"

      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all, limit: DEFAULT_LIMIT, sort: DEFAULT_SORT)
          new(scope: scope, limit: limit, sort: sort).rows
        end
      end

      def initialize(scope:, limit:, sort: DEFAULT_SORT)
        @scope = scope
        @limit = limit
        @sort = SORT_OPTIONS.key?(sort.to_s) ? sort.to_s : DEFAULT_SORT
      end

      def rows
        grouped_rows.map do |row|
          calls = row.calls_count.to_i
          total_cost = row.total_cost_sum.to_f

          TopModel.new(
            provider: row.provider,
            model: row.model,
            calls: calls,
            total_cost: total_cost,
            average_cost_per_call: calls.positive? ? total_cost / calls : 0.0,
            input_tokens: row.input_tokens_sum.to_i,
            output_tokens: row.output_tokens_sum.to_i,
            average_latency_ms: average_latency(row)
          )
        end
      end

      private

      attr_reader :scope, :limit, :sort

      def grouped_rows
        order_sql = sort == "latency" && !scope.klass.latency_column? ? "total_cost_sum DESC" : SORT_OPTIONS[sort]
        scope
          .group(:provider, :model)
          .select(selects)
          .order(Arel.sql(order_sql))
          .then { |r| limit ? r.limit(limit) : r }
      end

      def selects
        columns = [
          "provider",
          "model",
          "COUNT(*) AS calls_count",
          "COALESCE(SUM(total_cost), 0) AS total_cost_sum",
          "COALESCE(SUM(input_tokens), 0) AS input_tokens_sum",
          "COALESCE(SUM(output_tokens), 0) AS output_tokens_sum"
        ]
        columns << "AVG(latency_ms) AS average_latency" if scope.klass.latency_column?
        columns.join(", ")
      end

      def average_latency(row)
        return nil unless scope.klass.latency_column?

        row.average_latency&.to_f
      end
    end
  end
end
