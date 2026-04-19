# frozen_string_literal: true

LlmCostTracker::Engine.routes.draw do
  root "dashboard#index"
  resources :calls, only: %i[index show], constraints: { id: /\d+/ }
end
