# frozen_string_literal: true

require_relative "tag_sql"

module LlmCostTracker
  module LlmApiCallMetrics
    def total_cost
      sum(:total_cost).to_f
    end

    def total_tokens
      sum(:total_tokens).to_i
    end

    def cost_by_model
      group(:model).sum(:total_cost)
    end

    def cost_by_provider
      group(:provider).sum(:total_cost)
    end

    def group_by_tag(key)
      group(Arel.sql(tag_value_expression(key)))
    end

    def cost_by_tag(key, limit: nil)
      relation = group_by_tag(key).order(Arel.sql("COALESCE(SUM(total_cost), 0) DESC"))
      relation = relation.limit(limit) if limit

      costs = relation.sum(:total_cost).each_with_object(Hash.new(0.0)) do |(tag_value, cost), grouped|
        grouped[tag_value_label(tag_value)] += cost.to_f
      end
      costs.sort_by { |_label, cost| -cost }.to_h
    end

    def average_latency_ms
      return nil unless latency_column?

      average(:latency_ms)&.to_f
    end

    def latency_by_model
      return {} unless latency_column?

      group(:model).average(:latency_ms).transform_values(&:to_f)
    end

    def latency_by_provider
      return {} unless latency_column?

      group(:provider).average(:latency_ms).transform_values(&:to_f)
    end

    def tag_value_label(value)
      TagSql.value_label(value)
    end

    def tag_value_expression(key, table_name: quoted_table_name)
      TagSql.value_expression(self, key, table_name: table_name)
    end
  end
end
