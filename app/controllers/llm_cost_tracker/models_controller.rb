# frozen_string_literal: true

module LlmCostTracker
  class ModelsController < ApplicationController
    MAX_ROWS = 200

    def index
      @sort = params[:sort].to_s
      @dir = params[:dir].to_s
      @rows = Dashboard::TopModels.call(
        scope: Dashboard::Filter.call(params: params),
        limit: MAX_ROWS,
        sort: @sort,
        direction: @dir
      )
    end
  end
end
