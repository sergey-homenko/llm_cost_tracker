# frozen_string_literal: true

require "active_support/core_ext/integer/time"

require_relative "../ledger"

module LlmCostTracker
  class Report
    TopCall = ::Data.define(:provider, :model, :total_cost)

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
        scope = Ledger::Call.where(tracked_at: from..now)
        tag_breakdowns ||= LlmCostTracker.configuration.report_tag_breakdowns || []

        new(
          days: days,
          from_time: from,
          to_time: now,
          total_cost: scope.sum(:total_cost).to_f,
          requests_count: scope.count,
          average_latency_ms: average_latency_ms(scope),
          unknown_pricing_count: scope.where(total_cost: nil).count,
          cost_by_provider: cost_by(scope, :provider, limit: breakdown_limit),
          cost_by_model: cost_by(scope, :model, limit: breakdown_limit),
          cost_by_tags: cost_by_tags(scope, tag_breakdowns, limit: breakdown_limit),
          top_calls: top_calls(scope)
        )
      end

      def self.average_latency_ms(scope)
        return nil unless Ledger::Call.latency_column?

        scope.average(:latency_ms)&.to_f
      end

      def self.cost_by(scope, column, limit:)
        relation = scope.group(column)
                        .order(Arel.sql("COALESCE(SUM(total_cost), 0) DESC"))

        relation = relation.limit(limit) if limit

        relation
          .sum(:total_cost)
          .transform_values(&:to_f)
          .sort_by { |_name, cost| -cost }
      end

      def self.cost_by_tags(scope, keys, limit:)
        keys.to_h { |key| [key, scope.cost_by_tag(key, limit: limit).to_a] }
      end

      def self.top_calls(scope)
        scope
          .where.not(total_cost: nil)
          .order(total_cost: :desc)
          .limit(TOP_LIMIT)
          .map { |call| TopCall.new(provider: call.provider, model: call.model, total_cost: call.total_cost.to_f) }
      end

      private_class_method :average_latency_ms, :cost_by, :cost_by_tags, :top_calls
    end
  end
end
