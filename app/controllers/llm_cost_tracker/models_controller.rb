# frozen_string_literal: true

module LlmCostTracker
  class ModelsController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @sort = params[:sort].to_s
      @rows = Dashboard::TopModels.call(scope: scope, limit: nil, sort: @sort)
      @latency_available = LlmApiCall.latency_column?
    end
  end
end
