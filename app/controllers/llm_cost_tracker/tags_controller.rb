# frozen_string_literal: true

module LlmCostTracker
  class TagsController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @rows = Dashboard::TagKeyExplorer.call(scope: scope)
    end

    def show
      @tag_key = params[:key]
      scope = Dashboard::Filter.call(params: params)
      @rows = Dashboard::TagBreakdown.call(scope: scope, key: @tag_key)
      @total_calls = @rows.sum(&:calls)
      @tagged_calls = @rows.reject { |r| r.value == "(untagged)" }.sum(&:calls)
      @distinct_values = @rows.reject { |r| r.value == "(untagged)" }.size
    end
  end
end
