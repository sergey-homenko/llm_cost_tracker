# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    DataQualityStats = Data.define(
      :total_calls,
      :unknown_pricing_count,
      :untagged_calls_count,
      :missing_latency_count,
      :latency_column_present,
      :unknown_pricing_by_model
    )

    # Computes data quality metrics: coverage of cost, tags, and latency.
    class DataQuality
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all)
          total = scope.count
          latency_present = LlmCostTracker::LlmApiCall.latency_column?

          DataQualityStats.new(
            total_calls: total,
            unknown_pricing_count: scope.unknown_pricing.count,
            untagged_calls_count: total - scope.with_json_tags.count,
            missing_latency_count: latency_present ? scope.where(latency_ms: nil).count : nil,
            latency_column_present: latency_present,
            unknown_pricing_by_model: scope.unknown_pricing
                                      .group(:model)
                                      .order(Arel.sql("COUNT(*) DESC"))
                                      .count
                                      .first(10)
                                      .to_h
          )
        end
      end
    end
  end
end
