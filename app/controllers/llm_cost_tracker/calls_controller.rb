# frozen_string_literal: true

module LlmCostTracker
  class CallsController < ApplicationController
    def index
      @page = Pagination.call(params)
      scope = Dashboard::Filter.call(params: params)
      @calls_count = scope.count
      @calls = scope
               .order(tracked_at: :desc, id: :desc)
               .limit(@page.limit)
               .offset(@page.offset)
               .to_a
      @latency_available = LlmApiCall.latency_column?
    end

    def show
      @call = LlmApiCall.find(params[:id])
      @tags = @call.parsed_tags
      @metadata_available = @call.has_attribute?("metadata")
      @metadata = @call.read_attribute("metadata") if @metadata_available
      @latency_available = LlmApiCall.latency_column?
    end
  end
end
