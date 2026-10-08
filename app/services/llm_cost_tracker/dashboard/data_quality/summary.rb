# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module DataQuality
      Summary = ::Data.define(
        :total,
        :unknown_pricing_count,
        :untagged_calls_count,
        :missing_latency_count,
        :streaming_count,
        :streaming_missing_usage,
        :missing_provider_response_id_count
      ) do
        def self.from_stats(stats)
          new(
            total: stats.total_calls.to_i,
            unknown_pricing_count: stats.unknown_pricing_count.to_i,
            untagged_calls_count: stats.untagged_calls_count.to_i,
            missing_latency_count: stats.missing_latency_count.to_i,
            streaming_count: stats.streaming_count.to_i,
            streaming_missing_usage: stats.streaming_missing_usage_count.to_i,
            missing_provider_response_id_count: stats.missing_provider_response_id_count.to_i
          )
        end

        def calls_with_pricing = total - unknown_pricing_count
        def tagged_calls = total - untagged_calls_count
        def calls_with_latency = total - missing_latency_count
        def streams_with_usage = streaming_count - streaming_missing_usage
        def calls_with_provider_response_id = total - missing_provider_response_id_count

        def unknown_pricing_share = Percent.of(unknown_pricing_count, total)
        def untagged_share = Percent.of(untagged_calls_count, total)
        def missing_latency_share = Percent.of(missing_latency_count, total)
        def streaming_share = Percent.of(streaming_count, total)
        def streaming_missing_usage_share = Percent.of(streaming_missing_usage, streaming_count)

        def cost_coverage = Percent.of(calls_with_pricing, total)
        def tag_coverage = Percent.of(tagged_calls, total)
        def latency_coverage = Percent.of(calls_with_latency, total)
        def stream_coverage = Percent.of(streams_with_usage, streaming_count)
        def provider_response_id_coverage = Percent.of(calls_with_provider_response_id, total)
      end
    end
  end
end
