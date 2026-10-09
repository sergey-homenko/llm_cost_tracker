# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module DataQuality
      class StatsQuery
        MISSING_RESPONSE_ID = "provider_response_id IS NULL OR provider_response_id = ''"

        def self.call(scope)
          new(scope).call
        end

        def initialize(scope)
          @scope = scope
          @connection = scope.lease_connection
        end

        def call
          scope.unscope(:order).select(selects.join(", ")).take
        end

        private

        attr_reader :scope, :connection

        def selects
          [
            "COUNT(*) AS total_calls",
            "#{count_where(Charges::CostStatus.unknown_pricing_sql)} AS unknown_pricing_count",
            "COUNT(*) - #{count_where(tagged_predicate)} AS untagged_calls_count",
            "#{count_where('latency_ms IS NULL')} AS missing_latency_count",
            "#{count_where('stream')} AS streaming_count",
            "#{count_where(streaming_missing_usage_predicate)} AS streaming_missing_usage_count",
            "#{count_where(MISSING_RESPONSE_ID)} AS missing_provider_response_id_count",
            *token_sums,
            "#{billable_tokens} AS billable_tokens",
            "#{hidden_output_share} AS hidden_output_share"
          ]
        end

        def token_sums
          [*Usage::Catalog.token_priced.map(&:token_key), :hidden_output_tokens].map do |column|
            "#{column_sum(column)} AS #{column}"
          end
        end

        def billable_tokens
          Usage::Catalog.token_priced.map { |component| column_sum(component.token_key) }.join(" + ")
        end

        def hidden_output_share
          output = column_sum(:output_tokens)
          "CASE WHEN #{output} > 0 THEN #{column_sum(:hidden_output_tokens)} * 100.0 / #{output} ELSE 0 END"
        end

        def tagged_predicate
          tags = LlmCostTracker::CallTag.quoted_table_name
          calls = scope.klass.quoted_table_name
          "EXISTS (SELECT 1 FROM #{tags} WHERE #{tags}.llm_cost_tracker_call_id = #{calls}.id " \
            "AND #{tags}.#{connection.quote_column_name('value')} != '')"
        end

        def streaming_missing_usage_predicate
          "stream AND (#{DataQuality.unknown_usage_sql(connection)})"
        end

        def column_sum(column)
          "COALESCE(SUM(#{connection.quote_column_name(column)}), 0)"
        end

        def count_where(predicate)
          "COALESCE(SUM(CASE WHEN #{predicate} THEN 1 ELSE 0 END), 0)"
        end
      end
    end
  end
end
