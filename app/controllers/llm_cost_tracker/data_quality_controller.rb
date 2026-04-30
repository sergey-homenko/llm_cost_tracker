# frozen_string_literal: true

module LlmCostTracker
  class DataQualityController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @stats = Dashboard::DataQuality.call(scope: scope)
      @unknown_pricing_by_model = Dashboard::DataQuality.unknown_pricing_by_model(scope)
    end
  end
end
