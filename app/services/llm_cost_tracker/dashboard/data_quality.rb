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
      :token_usage_columns_present,
      *TokenUsage::DASHBOARD_SUM_KEYS,
      *Pricing::Cost::DASHBOARD_SUM_KEYS,
      :unknown_pricing_by_model
    )

    class DataQuality
      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all)
          model = scope.klass
          aggregates = DataQualityAggregate.call(scope: scope)
          total = aggregates.fetch(:total_calls).to_i

          DataQualityStats.new(
            total_calls: total,
            unknown_pricing_count: aggregates.fetch(:unknown_pricing_count).to_i,
            untagged_calls_count: total - aggregates.fetch(:tagged_calls_count).to_i,
            **latency_stats(aggregates, model:),
            **stream_stats(aggregates, model:),
            **provider_response_id_stats(aggregates, model:),
            **usage_stats(aggregates, model:),
            unknown_pricing_by_model: unknown_pricing_by_model(scope)
          )
        end

        private

        def latency_stats(aggregates, model:)
          latency_present = model.latency_column?

          {
            missing_latency_count: latency_present ? aggregates.fetch(:missing_latency_count).to_i : nil,
            latency_column_present: latency_present
          }
        end

        def stream_stats(aggregates, model:)
          stream_present = model.stream_column?
          usage_source_present = model.usage_source_column?
          streaming_missing_usage_count = nil
          if stream_present && usage_source_present
            streaming_missing_usage_count = aggregates.fetch(:streaming_missing_usage_count).to_i
          end

          {
            streaming_count: stream_present ? aggregates.fetch(:streaming_count).to_i : nil,
            streaming_missing_usage_count: streaming_missing_usage_count,
            stream_column_present: stream_present
          }
        end

        def provider_response_id_stats(aggregates, model:)
          column_present = model.provider_response_id_column?
          missing_provider_response_id_count = nil
          if column_present
            missing_provider_response_id_count = aggregates.fetch(:missing_provider_response_id_count).to_i
          end

          {
            missing_provider_response_id_count: missing_provider_response_id_count,
            provider_response_id_column_present: column_present
          }
        end

        def usage_stats(aggregates, model:)
          token_usage_present = model.token_usage_columns?
          token_usage_cost_present = model.token_usage_cost_columns?

          values = { token_usage_columns_present: token_usage_present }
          TokenUsage::DASHBOARD_SUM_KEYS.each do |key|
            values[key] = if TokenUsage::BASE_DASHBOARD_SUM_KEYS.include?(key) || token_usage_present
                            aggregates.fetch(key).to_i
                          end
          end
          Pricing::Cost::DASHBOARD_SUM_KEYS.each do |key|
            values[key] = if Pricing::Cost::BASE_DASHBOARD_SUM_KEYS.include?(key) || token_usage_cost_present
                            decimal_sum(aggregates.fetch(key))
                          end
          end
          values
        end

        def unknown_pricing_by_model(scope)
          scope.unknown_pricing
               .group(:model)
               .order(Arel.sql("COUNT(*) DESC"))
               .count
               .first(10)
               .to_h
        end

        def decimal_sum(value)
          value.to_f.round(8)
        end
      end
    end
  end
end
