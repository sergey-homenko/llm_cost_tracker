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

      tagged_rows = @rows.reject { |r| r.value == "(untagged)" }
      @tagged_calls = tagged_rows.sum(&:calls)
      @distinct_values = tagged_rows.size
    end
  end
end
