# frozen_string_literal: true

module LlmCostTracker
  class PricingController < ApplicationController
    def index
      @overview = Dashboard::PricingOverview.call
      @active_source = requested_source || @overview.fetch(:effective_source)
      @source_data = @overview.fetch(:sources).fetch(@active_source)
      @provider_filter = Dashboard::Params.scalar(params[:provider], :provider).presence
      @providers = @source_data.fetch(:rows).map(&:provider).compact.uniq.sort
      @rows = provider_rows(@source_data.fetch(:rows))
    end

    private

    def requested_source
      source = params[:source].to_s.to_sym
      source if @overview.fetch(:sources).key?(source)
    end

    def provider_rows(rows)
      return rows unless @provider_filter

      rows.select { |row| row.provider == @provider_filter }
    end
  end
end
