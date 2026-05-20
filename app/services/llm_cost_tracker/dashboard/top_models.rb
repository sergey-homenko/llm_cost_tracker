# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TopModels
      DEFAULT_LIMIT = 5
      SORT_OPTIONS = %w[cost calls avg_cost latency tokens provider name].freeze
      DEFAULT_SORT = "cost"
      DIRECTIONS = %w[asc desc].freeze
      DEFAULT_DIRECTIONS = {
        "provider" => "asc",
        "name" => "asc",
        "calls" => "desc",
        "tokens" => "desc",
        "latency" => "desc",
        "avg_cost" => "desc",
        "cost" => "desc"
      }.freeze
      ORDER_NODES = {
        %w[provider asc]  => [{ provider: :asc, model: :asc }],
        %w[provider desc] => [{ provider: :desc, model: :asc }],
        %w[name asc]      => [{ model: :asc }],
        %w[name desc]     => [{ model: :desc }],
        %w[calls asc]     => [Arel.sql("COUNT(*) ASC")],
        %w[calls desc]    => [Arel.sql("COUNT(*) DESC")],
        %w[tokens asc]    => [Arel.sql("COALESCE(SUM(total_tokens), 0) ASC")],
        %w[tokens desc]   => [Arel.sql("COALESCE(SUM(total_tokens), 0) DESC")],
        %w[avg_cost asc]  => [Arel.sql("COALESCE(SUM(total_cost), 0) / NULLIF(COUNT(*), 0) ASC")],
        %w[avg_cost desc] => [Arel.sql("COALESCE(SUM(total_cost), 0) / NULLIF(COUNT(*), 0) DESC")],
        %w[latency asc]   => [Arel.sql("CASE WHEN AVG(latency_ms) IS NULL THEN 1 ELSE 0 END ASC, " \
                                       "AVG(latency_ms) ASC")],
        %w[latency desc]  => [Arel.sql("CASE WHEN AVG(latency_ms) IS NULL THEN 1 ELSE 0 END ASC, " \
                                       "AVG(latency_ms) DESC")],
        %w[cost asc]      => [Arel.sql("COALESCE(SUM(total_cost), 0) ASC")],
        %w[cost desc]     => [Arel.sql("COALESCE(SUM(total_cost), 0) DESC")]
      }.freeze

      class << self
        def call(scope: LlmCostTracker::Call.all, limit: DEFAULT_LIMIT, sort: DEFAULT_SORT, direction: nil)
          new(scope: scope, limit: limit, sort: sort, direction: direction).rows
        end
      end

      def initialize(scope:, limit:, sort: DEFAULT_SORT, direction: nil)
        @scope = scope
        @limit = limit
        @sort = SORT_OPTIONS.include?(sort.to_s) ? sort.to_s : DEFAULT_SORT
        @direction = DIRECTIONS.include?(direction.to_s) ? direction.to_s : DEFAULT_DIRECTIONS[@sort]
      end

      def rows
        scope
          .group(:provider, :model)
          .select(selects)
          .order(*ORDER_NODES.fetch([sort, direction]))
          .then { |r| limit ? r.limit(limit) : r }
      end

      private

      attr_reader :scope, :limit, :sort, :direction

      def selects
        columns = [
          "provider",
          "model",
          "COUNT(*) AS calls",
          "COALESCE(SUM(total_cost), 0) AS total_cost",
          "COALESCE(SUM(total_cost), 0) / NULLIF(COUNT(*), 0) AS average_cost_per_call",
          "COALESCE(SUM(total_tokens), 0) AS total_tokens",
          "COALESCE(SUM(input_tokens), 0) AS input_tokens",
          "COALESCE(SUM(output_tokens), 0) AS output_tokens",
          "AVG(latency_ms) AS average_latency_ms"
        ]
        columns.join(", ")
      end
    end
  end
end
