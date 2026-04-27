# frozen_string_literal: true

module LlmCostTracker
  class TagsController < ApplicationController
    def index
      @rows = Dashboard::TagKeyExplorer.call(scope: Dashboard::Filter.call(params: params))
    end

    def show
      @tag_key = params[:key]
      breakdown = Dashboard::TagBreakdown.call(scope: Dashboard::Filter.call(params: params), key: @tag_key)
      @rows = breakdown.rows
      @total_calls = breakdown.total_calls
      @tagged_calls = breakdown.tagged_calls
      @distinct_values = breakdown.distinct_values
      @tag_value_limit = breakdown.limit
      @tag_values_limited = breakdown.limited?
    end
  end
end
