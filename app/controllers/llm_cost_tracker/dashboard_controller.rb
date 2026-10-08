# frozen_string_literal: true

module LlmCostTracker
  class DashboardController < ApplicationController
    def index
      previous_from, previous_to = previous_range
      scope = scope_between(@from_date, @to_date)
      previous_scope = scope_between(previous_from, previous_to)

      @stats = Dashboard::OverviewStats.call(scope: scope, previous_scope: previous_scope)
      @monthly_budget_status = Dashboard::MonthlyBudget.status
      @time_series = Dashboard::TimeSeries.call(scope: scope, from: @from_date, to: @to_date)
      @comparison_series = Dashboard::TimeSeries.call(scope: previous_scope, from: previous_from, to: previous_to)
      @spend_anomaly = Dashboard::SpendAnomaly.call(from: @from_date, to: @to_date, scope: scope)
      @top_models = Dashboard::TopModels.call(scope: scope)
      @providers = Dashboard::ProviderBreakdown.call(scope: scope)
    end

    private

    def scope_between(from, to)
      filter_params = Dashboard::Params.to_hash(params).merge("from" => from.iso8601, "to" => to.iso8601)
      Dashboard::Filter.call(params: filter_params)
    end

    def previous_range
      span_days = (@to_date - @from_date).to_i + 1
      previous_to = @from_date - 1
      [previous_to - (span_days - 1), previous_to]
    end
  end
end
