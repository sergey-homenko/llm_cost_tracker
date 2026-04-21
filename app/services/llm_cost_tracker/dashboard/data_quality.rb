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
      :unknown_pricing_by_model
    )

    class DataQuality
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all)
          total = scope.count
          latency_present = LlmCostTracker::LlmApiCall.latency_column?
          stream_present = LlmCostTracker::LlmApiCall.stream_column?

          DataQualityStats.new(
            total_calls: total,
            unknown_pricing_count: scope.unknown_pricing.count,
            untagged_calls_count: total - scope.with_json_tags.count,
            missing_latency_count: latency_present ? scope.where(latency_ms: nil).count : nil,
            latency_column_present: latency_present,
            streaming_count: stream_present ? scope.streaming.count : nil,
            streaming_missing_usage_count: streaming_missing_usage_count(scope, stream_present),
            stream_column_present: stream_present,
            unknown_pricing_by_model: scope.unknown_pricing
                                      .group(:model)
                                      .order(Arel.sql("COUNT(*) DESC"))
                                      .count
                                      .first(10)
                                      .to_h
          )
        end

        private

        def streaming_missing_usage_count(scope, stream_present)
          return nil unless stream_present
          return nil unless LlmCostTracker::LlmApiCall.usage_source_column?

          scope.streaming_missing_usage.count
        end
      end
    end
  end
end
