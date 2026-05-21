# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Anthropic
      module ServerTools
        LINE_ITEMS = {
          web_search_request: :web_search_requests,
          web_fetch_request: :web_fetch_requests,
          code_execution_request: :code_execution_requests
        }.freeze
      end
    end
  end
end
