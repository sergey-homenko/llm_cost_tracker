# frozen_string_literal: true

require "llm_cost_tracker/token_usage"
require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Dashboard
    class DataQuality
      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all)
          model = scope.klass
          scope.unscope(:order).select(aggregate_selects(scope, model:)).take
        end

        def unknown_pricing_by_model(scope)
          scope.unknown_pricing
               .group(:model)
               .order(Arel.sql("COUNT(*) DESC"))
               .select("model, COUNT(*) AS calls")
               .limit(10)
        end

        private

        def aggregate_selects(scope, model:)
          selects = [
            "COUNT(*) AS total_calls",
            "#{conditional_count_sql('total_cost IS NULL')} AS unknown_pricing_count",
            "#{tagged_calls_sql(model)} AS tagged_calls_count",
            "COUNT(*) - #{tagged_calls_sql(model)} AS untagged_calls_count",
            "#{conditional_count_sql('latency_ms IS NULL')} AS missing_latency_count",
            "#{conditional_count_sql('stream')} AS streaming_count",
            "#{streaming_missing_usage_select} AS streaming_missing_usage_count",
            "#{provider_response_id_select} AS missing_provider_response_id_count"
          ]

          usage_sum_columns.each do |column|
            selects << "COALESCE(SUM(#{scope.connection.quote_column_name(column)}), 0) AS #{column}"
          end

          selects.join(", ")
        end

        def usage_sum_columns
          TokenUsage::COMPONENTS.map { |component| component.fetch(:token_key) } +
            TokenUsage::PRICED_COMPONENTS.map { |component| component.fetch(:cost_key) }
        end

        def conditional_count_sql(predicate)
          "COALESCE(SUM(CASE WHEN #{predicate} THEN 1 ELSE 0 END), 0)"
        end

        def streaming_missing_usage_select
          predicate = "stream AND (usage_source = 'unknown' OR usage_source IS NULL)"
          conditional_count_sql(predicate)
        end

        def provider_response_id_select
          predicate = "provider_response_id IS NULL OR provider_response_id = ''"
          conditional_count_sql(predicate)
        end

        def tagged_calls_sql(model)
          table = model.quoted_table_name
          column = "#{table}.#{model.connection.quote_column_name('tags')}"

          if Ledger::Schema::Adapter.postgresql?(model.connection)
            "COALESCE(SUM(CASE WHEN #{column} <> '{}'::jsonb THEN 1 ELSE 0 END), 0)"
          else
            "COALESCE(SUM(CASE WHEN JSON_LENGTH(#{column}) > 0 THEN 1 ELSE 0 END), 0)"
          end
        end
      end
    end
  end
end
