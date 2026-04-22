# frozen_string_literal: true

module LlmCostTracker
  class DataQualityController < ApplicationController
    def index
      @stats = Dashboard::DataQuality.call(scope: Dashboard::Filter.call(params: params))
    end
  end
end
