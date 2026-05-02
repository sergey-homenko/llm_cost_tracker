# frozen_string_literal: true

module LlmCostTracker
  module DashboardFilterOptionsHelper
    MAX_FILTER_OPTIONS = 100

    def provider_filter_options(filter_params: params)
      filter_options_for(:provider, filter_params: filter_params)
    end

    def model_filter_options(filter_params: params)
      filter_options_for(:model, filter_params: filter_params)
    end

    private

    def filter_options_for(column, filter_params:)
      source = LlmCostTracker::Dashboard::Params.to_hash(filter_params).symbolize_keys
      scope_params = source.merge(
        column => nil, format: nil, page: nil, per: nil, sort: nil
      )
      values = LlmCostTracker::Dashboard::Filter.call(params: scope_params)
                                                .where.not(column => [nil, ""])
                                                .distinct.order(column).limit(MAX_FILTER_OPTIONS).pluck(column)
      current = source[column].presence
      values.unshift(current) if current && !values.include?(current)
      values
    end
  end
end
