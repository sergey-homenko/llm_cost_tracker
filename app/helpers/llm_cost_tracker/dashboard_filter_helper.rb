# frozen_string_literal: true

module LlmCostTracker
  module DashboardFilterHelper
    STREAM_FILTER_OPTIONS = [
      ["Streaming only", "yes"],
      ["Non-streaming only", "no"]
    ].freeze
  end
end
