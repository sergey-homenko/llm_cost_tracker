# frozen_string_literal: true

module LlmCostTracker
  class PricingController < ApplicationController
    def index
      @overview = Dashboard::PricingOverview.call
      requested = params[:source].to_s.to_sym
      @active_source = @overview.fetch(:sources).key?(requested) ? requested : @overview.fetch(:effective_source)
      @source_data = @overview.fetch(:sources).fetch(@active_source)
      @provider_filter = params[:provider].to_s.presence
      @rows = @source_data.fetch(:rows)
      @rows = @rows.select { |row| row.provider == @provider_filter } if @provider_filter
      @providers = @source_data.fetch(:rows).map(&:provider).compact.uniq.sort
    end
  end
end
