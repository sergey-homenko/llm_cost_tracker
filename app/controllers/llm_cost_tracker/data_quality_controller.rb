# frozen_string_literal: true

module LlmCostTracker
  class DataQualityController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @stats = Dashboard::DataQuality.call(scope: scope)
      @summary = Dashboard::DataQuality.summary(@stats)
      @usage_rows = Dashboard::DataQuality.usage_rows(@stats)
      @hidden_output_summary = Dashboard::DataQuality.hidden_output_summary(@stats)
      @unknown_pricing_by_model = Dashboard::DataQuality.unknown_pricing_by_model(
        scope,
        total_calls: @summary.total
      )
      @service_charge_rows = Dashboard::DataQuality.service_charge_rows(scope).to_a
    end
  end
end
