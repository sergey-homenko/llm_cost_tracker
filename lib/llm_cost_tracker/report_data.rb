# frozen_string_literal: true

require "active_support/core_ext/integer/time"

module LlmCostTracker
  TopCall = Data.define(:provider, :model, :total_cost)

  ReportData = Data.define(
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

  class ReportData
    DEFAULT_DAYS = 30
    TOP_LIMIT = 5

    def self.build(days: DEFAULT_DAYS, now: Time.now.utc, tag_breakdowns: nil)
      require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

      days = normalized_days(days)
      from = now - days.days
      scope = LlmApiCall.where(tracked_at: from..now)
      tag_breakdowns ||= LlmCostTracker.configuration.report_tag_breakdowns || []

      new(
        days: days,
        from_time: from,
        to_time: now,
        total_cost: scope.sum(:total_cost).to_f,
        requests_count: scope.count,
        average_latency_ms: average_latency_ms(scope),
        unknown_pricing_count: scope.where(total_cost: nil).count,
        cost_by_provider: cost_by(scope, :provider),
        cost_by_model: cost_by(scope, :model),
        cost_by_tags: cost_by_tags(scope, tag_breakdowns),
        top_calls: top_calls(scope)
      )
    end

    def self.normalized_days(days)
      days = days.to_i
      days.positive? ? days : DEFAULT_DAYS
    end

    def self.average_latency_ms(scope)
      return nil unless LlmApiCall.latency_column?

      scope.average(:latency_ms)&.to_f
    end

    def self.cost_by(scope, column)
      scope.group(column).sum(:total_cost).transform_values(&:to_f).sort_by { |_name, cost| -cost }
    end

    def self.cost_by_tags(scope, keys)
      keys.to_h { |key| [key, scope.cost_by_tag(key).to_a] }
    end

    def self.top_calls(scope)
      scope
        .where.not(total_cost: nil)
        .order(total_cost: :desc)
        .limit(TOP_LIMIT)
        .map { |call| TopCall.new(provider: call.provider, model: call.model, total_cost: call.total_cost.to_f) }
    end

    private_class_method :normalized_days, :average_latency_ms, :cost_by, :cost_by_tags, :top_calls
  end
end
