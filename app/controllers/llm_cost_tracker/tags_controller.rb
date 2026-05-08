# frozen_string_literal: true

module LlmCostTracker
  class TagsController < ApplicationController
    def index
      @rows = Dashboard::TagKeyExplorer.call(scope: Dashboard::Filter.call(params: params))
    end

    def show
      scope = Dashboard::Filter.call(params: params)
      @value = params[:value].to_s

      if @value.empty?
        @breakdown = Dashboard::TagBreakdown.call(scope: scope, key: params[:key])
      else
        @key = LlmCostTracker::Tags::Key.validate!(
          params[:key],
          error_class: LlmCostTracker::InvalidFilterError
        )
        value_scope = scope.by_tag(@key, @value)
        @value_total_cost = value_scope.sum(:total_cost).to_f
        @value_calls = value_scope.count
        @value_points = Dashboard::TimeSeries.call(scope: value_scope)
      end
    end
  end
end
