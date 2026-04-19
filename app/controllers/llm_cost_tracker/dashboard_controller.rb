# frozen_string_literal: true

module LlmCostTracker
  class DashboardController < ApplicationController
    def index
      @from_date, @to_date = overview_range
      scope = Dashboard::Filter.call(params: overview_filter_params)

      @stats = Dashboard::OverviewStats.call(scope: scope)
      @time_series = Dashboard::TimeSeries.call(scope: scope, from: @from_date, to: @to_date)
      @top_models = Dashboard::TopModels.call(scope: scope, limit: 5)
      @feature_costs = scope.cost_by_tag("feature").first(5)
    end

    private

    def overview_range
      to_date = parsed_date(params[:to]) || Date.current
      from_date = parsed_date(params[:from]) || (to_date - 29)
      [from_date, to_date]
    end

    def overview_filter_params
      params.to_unsafe_h.merge(
        "from" => @from_date.iso8601,
        "to" => @to_date.iso8601
      )
    end

    def parsed_date(value)
      return nil if value.to_s.strip.empty?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
