# frozen_string_literal: true

module LlmCostTracker
  class TagsController < ApplicationController
    def index
      @rows = Dashboard::TagKeyExplorer.call(scope: Dashboard::Filter.call(params: params))
    end

    def show
      @breakdown = Dashboard::TagBreakdown.call(scope: Dashboard::Filter.call(params: params), key: params[:key])
    end
  end
end
