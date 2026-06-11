# frozen_string_literal: true

module LlmCostTracker
  class DataQualityController < ApplicationController
    def index
      scope = Dashboard::Filter.call(params: params)
      @stats = Dashboard::DataQuality.call(scope: scope)
      @summary = Dashboard::DataQuality.summary(@stats)
      @usage_rows = Dashboard::DataQuality.usage_rows(
        @stats,
        component_costs: Dashboard::DataQuality.component_costs(scope)
      )
      @hidden_output_summary = Dashboard::DataQuality.hidden_output_summary(@stats)
      @unknown_pricing_by_model = Dashboard::DataQuality.unknown_pricing_by_model(
        scope,
        total_calls: @summary.total
      )
      @service_charge_rows = Dashboard::DataQuality.service_charge_rows(scope).to_a
      @streaming_health_rows = Dashboard::DataQuality.streaming_health_rows(
        scope,
        total_streaming: @summary.streaming_count
      )
      @quarantined_inbox = Dashboard::DataQuality.quarantined_inbox
    end
  end
end
