# frozen_string_literal: true

require "llm_cost_tracker/llm_api_call"

module LlmCostTracker
  class DashboardController < ApplicationController
    def index
      @calls_count = llm_api_calls_table_available? ? LlmCostTracker::LlmApiCall.count : 0
    end
  end
end
