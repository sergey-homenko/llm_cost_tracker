# frozen_string_literal: true

Rails.application.routes.draw do
  mount LlmCostTracker::Engine => "/llm-costs"
end
