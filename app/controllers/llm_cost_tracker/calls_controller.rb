# frozen_string_literal: true

require "llm_cost_tracker/llm_api_call"
require_relative "../../services/llm_cost_tracker/dashboard/filter"
require_relative "../../services/llm_cost_tracker/dashboard/page"

module LlmCostTracker
  class CallsController < ApplicationController
    def index
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
      @call = LlmCostTracker::LlmApiCall.find(params[:id])
      @tags = @call.parsed_tags
      @metadata_available = @call.has_attribute?("metadata")
      @metadata = @call.read_attribute("metadata") if @metadata_available
      @latency_available = LlmCostTracker::LlmApiCall.latency_column?
    end

    private

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
