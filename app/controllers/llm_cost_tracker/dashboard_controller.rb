# frozen_string_literal: true

module LlmCostTracker
  class DashboardController < ApplicationController
    def index
      @from_date, @to_date = overview_range
      prev_from, prev_to = previous_range
      filter_params = LlmCostTracker::ParameterHash.to_hash(params)
      scope = Dashboard::Filter.call(
        params: filter_params.merge("from" => @from_date.iso8601, "to" => @to_date.iso8601)
      )
      previous_scope = Dashboard::Filter.call(
        params: filter_params.merge("from" => prev_from.iso8601, "to" => prev_to.iso8601)
      )

      @stats = Dashboard::OverviewStats.call(scope: scope, previous_scope: previous_scope)
      @time_series = Dashboard::TimeSeries.call(scope: scope, from: @from_date, to: @to_date)
      @comparison_series = Dashboard::TimeSeries.call(scope: previous_scope, from: prev_from, to: prev_to)
      @spend_anomaly = Dashboard::SpendAnomaly.call(from: @from_date, to: @to_date, scope: scope)
      @top_models = Dashboard::TopModels.call(scope: scope)
      @providers = Dashboard::ProviderBreakdown.call(scope: scope)
    end

    private

    def overview_range
      to_date = parsed_date(params[:to]) || Date.current
      from_date = parsed_date(params[:from]) || (to_date - 29)
      [from_date, to_date]
    end

    def previous_range
      span_days = (@to_date - @from_date).to_i + 1
      prev_to = @from_date - 1
      prev_from = prev_to - (span_days - 1)
      [prev_from, prev_to]
    end

    def parsed_date(value)
      return nil if value.to_s.strip.empty?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
