# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class DataQualityAggregate
      class << self
        def call(scope:)
          model = scope.klass
          expressions = aggregate_expressions(scope, model:)
          values = Array(scope.unscope(:order).pick(*expressions.values))

          expressions.keys.zip(values).to_h
        end

        private

        def aggregate_expressions(scope, model:)
          usage_breakdown_present = model.usage_breakdown_columns?
          usage_breakdown_cost_present = model.usage_breakdown_cost_columns?

          expressions = {
            total_calls: Arel.sql("COUNT(*)"),
            unknown_pricing_count: conditional_count_expression("total_cost IS NULL"),
            tagged_calls_count: tagged_calls_expression(model)
          }

          if model.latency_column?
            expressions[:missing_latency_count] = conditional_count_expression("latency_ms IS NULL")
          end
          expressions[:streaming_count] = conditional_count_expression("stream") if model.stream_column?
          if model.stream_column? && model.usage_source_column?
            expressions[:streaming_missing_usage_count] =
              conditional_count_expression("stream AND (usage_source = 'unknown' OR usage_source IS NULL)")
          end
          if model.provider_response_id_column?
            expressions[:missing_provider_response_id_count] =
              conditional_count_expression("provider_response_id IS NULL OR provider_response_id = ''")
          end

          usage_sum_columns(usage_breakdown_present, usage_breakdown_cost_present).each do |column|
            expressions[column] = sum_expression(scope, column)
          end

          expressions
        end

        def usage_sum_columns(usage_breakdown_present, usage_breakdown_cost_present)
          columns = %i[input_tokens output_tokens input_cost output_cost]
          if usage_breakdown_present
            columns += %i[cache_read_input_tokens cache_write_input_tokens hidden_output_tokens]
          end
          columns += %i[cache_read_input_cost cache_write_input_cost] if usage_breakdown_cost_present
          columns
        end

        def conditional_count_expression(predicate)
          Arel.sql("COALESCE(SUM(CASE WHEN #{predicate} THEN 1 ELSE 0 END), 0)")
        end

        def tagged_calls_expression(model)
          table = model.quoted_table_name
          column = "#{table}.#{model.connection.quote_column_name('tags')}"

          Arel.sql(case
                   when model.tags_jsonb_column?
                     "COALESCE(SUM(CASE WHEN #{column} <> '{}'::jsonb THEN 1 ELSE 0 END), 0)"
                   when model.tags_mysql_json_column?
                     "COALESCE(SUM(CASE WHEN JSON_LENGTH(#{column}) > 0 THEN 1 ELSE 0 END), 0)"
                   else
                     "COALESCE(SUM(CASE WHEN #{column} IS NOT NULL AND #{column} <> '' " \
                     "AND #{column} <> '{}' THEN 1 ELSE 0 END), 0)"
                   end)
        end

        def sum_expression(scope, column)
          Arel.sql("COALESCE(SUM(#{scope.connection.quote_column_name(column)}), 0)")
        end
      end
    end
  end
end
