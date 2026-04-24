# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    DataQualityStats = Data.define(
      :total_calls,
      :unknown_pricing_count,
      :untagged_calls_count,
      :missing_latency_count,
      :latency_column_present,
      :streaming_count,
      :streaming_missing_usage_count,
      :stream_column_present,
      :missing_provider_response_id_count,
      :provider_response_id_column_present,
      :usage_breakdown_column_present,
      :input_tokens,
      :cache_read_input_tokens,
      :cache_write_input_tokens,
      :output_tokens,
      :hidden_output_tokens,
      :input_cost,
      :cache_read_input_cost,
      :cache_write_input_cost,
      :output_cost,
      :unknown_pricing_by_model
    )

    class DataQuality
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all)
          total = scope.count

          DataQualityStats.new(
            total_calls: total,
            unknown_pricing_count: scope.unknown_pricing.count,
            untagged_calls_count: total - scope.with_json_tags.count,
            **latency_stats(scope),
            **stream_stats(scope),
            **provider_response_id_stats(scope),
            **usage_stats(scope),
            unknown_pricing_by_model: unknown_pricing_by_model(scope)
          )
        end

        private

        def latency_stats(scope)
          latency_present = LlmCostTracker::LlmApiCall.latency_column?

          {
            missing_latency_count: latency_present ? scope.where(latency_ms: nil).count : nil,
            latency_column_present: latency_present
          }
        end

        def stream_stats(scope)
          stream_present = LlmCostTracker::LlmApiCall.stream_column?

          {
            streaming_count: stream_present ? scope.streaming.count : nil,
            streaming_missing_usage_count: streaming_missing_usage_count(scope, stream_present),
            stream_column_present: stream_present
          }
        end

        def provider_response_id_stats(scope)
          column_present = LlmCostTracker::LlmApiCall.provider_response_id_column?

          {
            missing_provider_response_id_count: column_present ? scope.missing_provider_response_id.count : nil,
            provider_response_id_column_present: column_present
          }
        end

        def usage_stats(scope)
          usage_breakdown_present = LlmCostTracker::LlmApiCall.usage_breakdown_columns?
          usage_breakdown_cost_present = LlmCostTracker::LlmApiCall.usage_breakdown_cost_columns?
          sums = sum_columns(scope, usage_sum_columns(usage_breakdown_present, usage_breakdown_cost_present))

          {
            usage_breakdown_column_present: usage_breakdown_present,
            input_tokens: sums[:input_tokens].to_i,
            cache_read_input_tokens: usage_breakdown_present ? sums[:cache_read_input_tokens].to_i : nil,
            cache_write_input_tokens: usage_breakdown_present ? sums[:cache_write_input_tokens].to_i : nil,
            output_tokens: sums[:output_tokens].to_i,
            hidden_output_tokens: usage_breakdown_present ? sums[:hidden_output_tokens].to_i : nil,
            input_cost: decimal_sum(sums[:input_cost]),
            cache_read_input_cost: usage_breakdown_cost_present ? decimal_sum(sums[:cache_read_input_cost]) : nil,
            cache_write_input_cost: usage_breakdown_cost_present ? decimal_sum(sums[:cache_write_input_cost]) : nil,
            output_cost: decimal_sum(sums[:output_cost])
          }
        end

        def usage_sum_columns(usage_breakdown_present, usage_breakdown_cost_present)
          columns = %i[input_tokens output_tokens input_cost output_cost]
          if usage_breakdown_present
            columns += %i[cache_read_input_tokens cache_write_input_tokens hidden_output_tokens]
          end
          columns += %i[cache_read_input_cost cache_write_input_cost] if usage_breakdown_cost_present
          columns
        end

        def streaming_missing_usage_count(scope, stream_present)
          return unless stream_present && LlmCostTracker::LlmApiCall.usage_source_column?

          scope.streaming_missing_usage.count
        end

        def unknown_pricing_by_model(scope)
          scope.unknown_pricing
               .group(:model)
               .order(Arel.sql("COUNT(*) DESC"))
               .count
               .first(10)
               .to_h
        end

        def sum_columns(scope, columns)
          values = scope.unscope(:order).pick(*columns.map { |column| sum_expression(scope, column) })

          columns.zip(values).to_h
        end

        def sum_expression(scope, column)
          Arel.sql("COALESCE(SUM(#{scope.connection.quote_column_name(column)}), 0)")
        end

        def decimal_sum(value)
          value.to_f.round(8)
        end
      end
    end
  end
end
