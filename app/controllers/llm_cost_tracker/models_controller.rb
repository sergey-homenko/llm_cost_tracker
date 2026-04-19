# frozen_string_literal: true

module LlmCostTracker
  class ModelsController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @rows = Dashboard::TopModels.call(scope: scope, limit: nil)
      @latency_available = LlmApiCall.latency_column?
    end
  end
end
