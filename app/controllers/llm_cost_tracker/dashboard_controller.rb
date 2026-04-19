# frozen_string_literal: true

require "llm_cost_tracker/llm_api_call"
require_relative "../../services/llm_cost_tracker/dashboard/filter"
require_relative "../../services/llm_cost_tracker/dashboard/overview_stats"
require_relative "../../services/llm_cost_tracker/dashboard/time_series"
require_relative "../../services/llm_cost_tracker/dashboard/top_models"
require_relative "../../services/llm_cost_tracker/dashboard/top_tags"

module LlmCostTracker
  class DashboardController < ApplicationController
    def index
      return render_setup_state unless llm_api_calls_table_available?

      @from_date, @to_date = overview_range
      scope = Dashboard::Filter.apply(params: overview_filter_params)

      @stats = Dashboard::OverviewStats.build(scope: scope)
      @time_series = Dashboard::TimeSeries.call(scope: scope, from: @from_date, to: @to_date)
      @top_models = Dashboard::TopModels.call(scope: scope, limit: 5)
      @top_tags = Dashboard::TopTags.call(scope: scope, limit: 5)
    end

    private

    def render_setup_state
      @setup_required = true
      render :index
    end

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
