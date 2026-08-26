# frozen_string_literal: true

require "active_support/core_ext/integer/time"

require_relative "../charges/cost_status"
require_relative "../ledger"

module LlmCostTracker
  module Report
    Data = ::Data.define(
      :days,
      :from_time,
      :to_time,
      :total_cost,
      :requests_count,
      :average_latency_ms,
      :unknown_pricing_count,
      :cost_by_provider,
      :cost_by_model,
      :cost_by_tags,
      :top_calls
    )

    class Data
      DEFAULT_DAYS = 30
      TOP_LIMIT = 5

      def self.build(days: DEFAULT_DAYS, now: Time.now.utc, tag_breakdowns: nil, breakdown_limit: nil)
        days = days.to_i
        days = DEFAULT_DAYS unless days.positive?
        unless breakdown_limit.nil?
          breakdown_limit = breakdown_limit.to_i
          breakdown_limit = nil unless breakdown_limit.positive?
        end
        from = now - days.days
        scope = LlmCostTracker::Call.where(tracked_at: from..now)
        tag_breakdowns ||= LlmCostTracker.configuration.tags.report_breakdown_keys || []
        aggregate = totals(scope)

        new(
          days: days,
          from_time: from,
          to_time: now,
          total_cost: aggregate.total_cost.to_f,
          requests_count: aggregate.requests_count.to_i,
          average_latency_ms: aggregate.average_latency_ms&.to_f,
          unknown_pricing_count: aggregate.unknown_pricing_count.to_i,
          cost_by_provider: scope.cost_by_provider(limit: breakdown_limit).to_a,
          cost_by_model: scope.cost_by_model(limit: breakdown_limit).to_a,
          cost_by_tags: cost_by_tags(scope, tag_breakdowns, limit: breakdown_limit),
          top_calls: top_calls(scope)
        )
      end

      def self.totals(scope)
        scope
          .select(
            "COALESCE(SUM(#{LlmCostTracker::Call.qualified_total_cost}), 0) AS total_cost, " \
            "COUNT(*) AS requests_count, " \
            "AVG(latency_ms) AS average_latency_ms, " \
            "COALESCE(SUM(CASE WHEN #{Charges::CostStatus.unknown_pricing_sql} " \
            "THEN 1 ELSE 0 END), 0) AS unknown_pricing_count"
          )
          .take
      end

      def self.cost_by_tags(scope, keys, limit:)
        keys.to_h { |key| [key, scope.cost_by_tag(key, limit: limit).to_a] }
      end

      def self.top_calls(scope)
        scope
          .where.not(total_cost: nil)
          .order(total_cost: :desc)
          .limit(TOP_LIMIT)
          .to_a
      end

      private_class_method :cost_by_tags, :top_calls, :totals
    end
  end
end
