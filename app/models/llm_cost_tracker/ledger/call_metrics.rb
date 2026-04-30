# frozen_string_literal: true

require "llm_cost_tracker/ledger/tags/sql"

module LlmCostTracker
  module Ledger
    module CallMetrics
      def total_cost
        sum(:total_cost).to_f
      end

      def total_tokens
        sum(:total_tokens).to_i
      end

      def cost_by_model(limit: nil)
        cost_by_column(:model, limit: limit)
      end

      def cost_by_provider(limit: nil)
        cost_by_column(:provider, limit: limit)
      end

      def group_by_tag(key)
        group(Arel.sql(tag_value_expression(key)))
      end

      def cost_by_tag(key, limit: nil)
        expression = tag_value_expression(key)
        label_expression = "COALESCE(NULLIF(#{expression}, ''), #{connection.quote('(untagged)')})"
        relation = select("#{label_expression} AS name, COALESCE(SUM(total_cost), 0) AS total_cost")
                   .group(Arel.sql(label_expression))
                   .order(Arel.sql("COALESCE(SUM(total_cost), 0) DESC"))
        relation = relation.limit(limit) if limit
        relation
      end

      def average_latency_ms
        average(:latency_ms)&.to_f
      end

      def latency_by_model
        group(:model).average(:latency_ms).transform_values(&:to_f)
      end

      def latency_by_provider
        group(:provider).average(:latency_ms).transform_values(&:to_f)
      end

      def tag_value_label(value)
        Ledger::Tags::Sql.value_label(value)
      end

      def tag_value_expression(key, table_name: quoted_table_name)
        Ledger::Tags::Sql.value_expression(self, key, table_name: table_name)
      end

      private

      def cost_by_column(column, limit:)
        quoted_column = "#{quoted_table_name}.#{connection.quote_column_name(column)}"
        relation = select("#{quoted_column} AS name, COALESCE(SUM(total_cost), 0) AS total_cost")
                   .group(column)
                   .order(Arel.sql("COALESCE(SUM(total_cost), 0) DESC"))
        relation = relation.limit(limit) if limit
        relation
      end
    end
  end
end
