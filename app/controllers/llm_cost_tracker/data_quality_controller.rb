# frozen_string_literal: true

module LlmCostTracker
  class DataQualityController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @stats = Dashboard::DataQuality.call(scope: scope)
      @usage_rows = Dashboard::DataQuality.usage_rows(@stats)
      @hidden_output_summary = Dashboard::DataQuality.hidden_output_summary(@stats)
      @unknown_pricing_by_model = Dashboard::DataQuality.unknown_pricing_by_model(scope)
    end
  end
end
