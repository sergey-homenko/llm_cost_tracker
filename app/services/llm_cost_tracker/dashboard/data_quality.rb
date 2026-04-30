# frozen_string_literal: true

require "llm_cost_tracker/token_usage"

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
          token_usage_present = model.token_usage_columns?
          token_usage_cost_present = model.token_usage_cost_columns?

          selects = [
            "COUNT(*) AS total_calls",
            "#{conditional_count_sql('total_cost IS NULL')} AS unknown_pricing_count",
            "#{tagged_calls_sql(model)} AS tagged_calls_count",
            "COUNT(*) - #{tagged_calls_sql(model)} AS untagged_calls_count"
          ]

          selects << if model.latency_column?
                       "#{conditional_count_sql('latency_ms IS NULL')} AS missing_latency_count"
                     else
                       "NULL AS missing_latency_count"
                     end
          selects << if model.stream_column?
                       "#{conditional_count_sql('stream')} AS streaming_count"
                     else
                       "NULL AS streaming_count"
                     end
          selects << streaming_missing_usage_select(model)
          selects << provider_response_id_select(model)

          usage_sum_columns(token_usage_present, token_usage_cost_present).each do |column, present|
            selects << if present
                         "COALESCE(SUM(#{scope.connection.quote_column_name(column)}), 0) AS #{column}"
                       else
                         "NULL AS #{column}"
                       end
          end

          selects.join(", ")
        end

        def usage_sum_columns(token_usage_present, token_usage_cost_present)
          TokenUsage::BASE_COMPONENTS.map { |component| [component.fetch(:token_key), true] } +
            TokenUsage::BASE_PRICED_COMPONENTS.map { |component| [component.fetch(:cost_key), true] } +
            TokenUsage::OPTIONAL_COMPONENTS.map { |component| [component.fetch(:token_key), token_usage_present] } +
            TokenUsage::OPTIONAL_PRICED_COMPONENTS.map do |component|
              [component.fetch(:cost_key), token_usage_cost_present]
            end
        end

        def conditional_count_sql(predicate)
          "COALESCE(SUM(CASE WHEN #{predicate} THEN 1 ELSE 0 END), 0)"
        end

        def streaming_missing_usage_select(model)
          return "NULL AS streaming_missing_usage_count" unless model.stream_column? && model.usage_source_column?

          predicate = "stream AND (usage_source = 'unknown' OR usage_source IS NULL)"
          "#{conditional_count_sql(predicate)} AS streaming_missing_usage_count"
        end

        def provider_response_id_select(model)
          return "NULL AS missing_provider_response_id_count" unless model.provider_response_id_column?

          predicate = "provider_response_id IS NULL OR provider_response_id = ''"
          "#{conditional_count_sql(predicate)} AS missing_provider_response_id_count"
        end

        def tagged_calls_sql(model)
          table = model.quoted_table_name
          column = "#{table}.#{model.connection.quote_column_name('tags')}"

          if model.tags_jsonb_column?
            "COALESCE(SUM(CASE WHEN #{column} <> '{}'::jsonb THEN 1 ELSE 0 END), 0)"
          elsif model.tags_mysql_json_column?
            "COALESCE(SUM(CASE WHEN JSON_LENGTH(#{column}) > 0 THEN 1 ELSE 0 END), 0)"
          else
            <<~SQL.squish
              COALESCE(SUM(CASE WHEN #{column} IS NOT NULL AND #{column} <> ''
              AND #{column} <> '{}' THEN 1 ELSE 0 END), 0)
            SQL
          end
        end
      end
    end
  end
end
