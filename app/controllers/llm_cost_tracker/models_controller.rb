# frozen_string_literal: true

module LlmCostTracker
  class ModelsController < ApplicationController
    MAX_ROWS = 200

    def index
      @rows = Dashboard::TopModels.call(
        scope: Dashboard::Filter.call(params: params),
        limit: MAX_ROWS,
        sort: params[:sort].to_s,
        direction: params[:dir].to_s
      )
    end
  end
end
