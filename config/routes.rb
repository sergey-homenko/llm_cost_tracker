# frozen_string_literal: true

LlmCostTracker::Engine.routes.draw do
  root "dashboard#index"
  get "calls", to: "dashboard#calls", as: :calls
  get "calls/:id", to: "dashboard#show", as: :call, constraints: { id: /\d+/ }
end
