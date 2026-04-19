# frozen_string_literal: true

module LlmCostTracker
  class DataQualityController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @stats = Dashboard::DataQuality.call(scope: scope)
    end
  end
end
