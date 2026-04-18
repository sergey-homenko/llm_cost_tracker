# frozen_string_literal: true

require_relative "value_object"

module LlmCostTracker
  TopCall = ValueObject.define(:provider, :model, :total_cost)

  ReportData = ValueObject.define(
    :days,
    :from_time,
    :to_time,
    :total_cost,
    :requests_count,
    :average_latency_ms,
    :unknown_pricing_count,
    :cost_by_provider,
    :cost_by_model,
    :cost_by_feature,
    :top_calls
  )

  ReportData.const_set(:DEFAULT_DAYS, 30)
  ReportData.const_set(:TOP_LIMIT, 5)

  class << ReportData
    def build(days: ReportData::DEFAULT_DAYS, now: Time.now.utc)
      require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)

      days = normalized_days(days)
      scope = LlmApiCall.where(tracked_at: from_time(days, now)..now)

      new(
        days: days,
        from_time: from_time(days, now),
        to_time: now,
        total_cost: scope.sum(:total_cost).to_f,
        requests_count: scope.count,
        average_latency_ms: average_latency_ms(scope),
        unknown_pricing_count: scope.where(total_cost: nil).count,
        cost_by_provider: cost_by(scope, :provider),
        cost_by_model: cost_by(scope, :model),
        cost_by_feature: cost_by_feature(scope),
        top_calls: top_calls(scope)
      )
    end

    private

    def normalized_days(days)
      days = days.to_i
      days.positive? ? days : ReportData::DEFAULT_DAYS
    end

    def from_time(days, now)
      now - (days * 86_400)
    end

    def average_latency_ms(scope)
      return nil unless LlmApiCall.latency_column?

      scope.average(:latency_ms)&.to_f
    end

    def cost_by(scope, column)
      scope.group(column).sum(:total_cost).transform_values(&:to_f).sort_by { |_name, cost| -cost }
    end

    def cost_by_feature(scope)
      costs = Hash.new(0.0)
      scope.select(:id, :tags, :total_cost).find_each do |call|
        costs[call.feature || "(untagged)"] += call.total_cost.to_f
      end
      costs.sort_by { |_feature, cost| -cost }
    end

    def top_calls(scope)
      scope
        .where.not(total_cost: nil)
        .order(total_cost: :desc)
        .limit(ReportData::TOP_LIMIT)
        .map { |call| TopCall.new(provider: call.provider, model: call.model, total_cost: call.total_cost.to_f) }
    end
  end
end
