# frozen_string_literal: true

require "llm_cost_tracker/llm_api_call"
require_relative "../../services/llm_cost_tracker/dashboard/filter"
require_relative "../../services/llm_cost_tracker/dashboard/overview_stats"
require_relative "../../services/llm_cost_tracker/dashboard/page"
require_relative "../../services/llm_cost_tracker/dashboard/time_series"
require_relative "../../services/llm_cost_tracker/dashboard/top_models"
require_relative "../../services/llm_cost_tracker/dashboard/top_tags"

module LlmCostTracker
  class DashboardController < ApplicationController
    def index
      return render_setup_state unless llm_api_calls_table_available?

      @from_date, @to_date = overview_range
      scope = Dashboard::Filter.apply(params: overview_filter_params)

      @stats = Dashboard::OverviewStats.build(scope: scope)
      @time_series = Dashboard::TimeSeries.call(scope: scope, from: @from_date, to: @to_date)
      @top_models = Dashboard::TopModels.call(scope: scope, limit: 5)
      @top_tags = Dashboard::TopTags.call(scope: scope, limit: 5)
    end

    def calls
      return render_setup_state unless llm_api_calls_table_available?

      @page = Dashboard::Page.from(params)
      @filter_params = calls_filter_params
      @tag_key, @tag_value = calls_tag_filter_pair(@filter_params)

      scope = Dashboard::Filter.apply(params: @filter_params)
      @calls_count = scope.count
      @calls = scope
               .order(tracked_at: :desc, id: :desc)
               .limit(@page.limit)
               .offset(@page.offset)
               .to_a
      @latency_available = LlmCostTracker::LlmApiCall.latency_column?
    end

    def show
      return render_setup_state unless llm_api_calls_table_available?

      @call = LlmCostTracker::LlmApiCall.find(params[:id])
      @tags = @call.parsed_tags
      @metadata_available = @call.has_attribute?("metadata")
      @metadata = @call.read_attribute("metadata") if @metadata_available
      @latency_available = LlmCostTracker::LlmApiCall.latency_column?
    end

    private

    def render_setup_state
      @setup_required = true
      render action_name
    end

    def overview_range
      to_date = parsed_date(params[:to]) || Date.current
      from_date = parsed_date(params[:from]) || (to_date - 29)
      [from_date, to_date]
    end

    def overview_filter_params
      params.to_unsafe_h.merge(
        "from" => @from_date.iso8601,
        "to" => @to_date.iso8601
      )
    end

    def parsed_date(value)
      return nil if value.to_s.strip.empty?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def calls_filter_params
      raw_params = params.to_unsafe_h.except("controller", "action")
      tag_key = normalized_string(raw_params.delete("tag_key"))
      tag_value = normalized_string(raw_params.delete("tag_value"))

      if tag_key && tag_value
        raw_params["tag"] = raw_params["tag"].is_a?(Hash) ? raw_params["tag"].dup : {}
        raw_params["tag"][tag_key] = tag_value
      end

      raw_params
    end

    def calls_tag_filter_pair(filter_params)
      tags = filter_params["tag"]
      return [nil, nil] unless tags.is_a?(Hash)

      key, value = tags.first
      [key, value]
    end

    def normalized_string(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end
