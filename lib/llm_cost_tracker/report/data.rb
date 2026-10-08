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
        days = positive_integer(days) || DEFAULT_DAYS
        limit = positive_integer(breakdown_limit)
        from = now - days.days
        scope = LlmCostTracker::Call.where(tracked_at: from..now)
        tag_keys = tag_breakdowns || LlmCostTracker.configuration.tags.report_breakdown_keys

        new(
          days: days,
          from_time: from,
          to_time: now,
          **totals(scope),
          cost_by_provider: scope.cost_by_provider(limit: limit).to_a,
          cost_by_model: scope.cost_by_model(limit: limit).to_a,
          cost_by_tags: tag_keys.to_h { |key| [key, scope.cost_by_tag(key, limit: limit).to_a] },
          top_calls: top_calls(scope)
        )
      end

      def self.positive_integer(value)
        integer = value.to_i
        integer if integer.positive?
      end

      def self.totals(scope)
        row = scope.select(
          "COALESCE(SUM(#{LlmCostTracker::Call.qualified(:total_cost)}), 0) AS total_cost, " \
          "COUNT(*) AS requests_count, " \
          "AVG(latency_ms) AS average_latency_ms, " \
          "COALESCE(SUM(CASE WHEN #{Charges::CostStatus.unknown_pricing_sql} " \
          "THEN 1 ELSE 0 END), 0) AS unknown_pricing_count"
        ).take
        {
          total_cost: row.total_cost.to_f,
          requests_count: row.requests_count.to_i,
          average_latency_ms: row.average_latency_ms&.to_f,
          unknown_pricing_count: row.unknown_pricing_count.to_i
        }
      end

      def self.top_calls(scope)
        scope
          .where.not(total_cost: nil)
          .order(total_cost: :desc)
          .limit(TOP_LIMIT)
          .to_a
      end

      private_class_method :positive_integer, :totals, :top_calls
    end
  end
end
