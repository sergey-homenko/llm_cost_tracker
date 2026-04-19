# frozen_string_literal: true

module LlmCostTracker
  class TagsController < ApplicationController
    def show
      @tag_key = params[:key]
      scope = Dashboard::Filter.call(params: params)
      @rows = Dashboard::TagBreakdown.call(scope: scope, key: @tag_key)
    end
  end
end
