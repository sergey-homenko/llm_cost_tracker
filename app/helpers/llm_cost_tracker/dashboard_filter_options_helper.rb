# frozen_string_literal: true

module LlmCostTracker
  module DashboardFilterOptionsHelper
    def provider_filter_options(filter_params: params)
      filter_options_for(:provider, filter_params: filter_params)
    end

    def model_filter_options(filter_params: params)
      filter_options_for(:model, filter_params: filter_params)
    end

    private

    def filter_options_for(column, filter_params:)
      source = LlmCostTracker::ParameterHash.to_hash(filter_params)
      scope_params = source.stringify_keys.merge(
        column.to_s => nil, "format" => nil, "page" => nil, "per" => nil, "sort" => nil
      )
      values = LlmCostTracker::Dashboard::Filter.call(params: scope_params)
                                                .where.not(column => [nil, ""])
                                                .distinct.order(column).pluck(column)
      current = source[column.to_s].presence || source[column].presence
      values.unshift(current) if current && !values.include?(current)
      values
    end
  end
end
