# frozen_string_literal: true

LlmCostTracker::Engine.routes.draw do
  root "dashboard#index"
  resources :calls, only: %i[index show], constraints: { id: /\d+/ }, defaults: { format: :html }
  resources :models, only: :index
  get "tags",      to: "tags#index",  as: :tags
  get "tags/:key", to: "tags#show",   as: :tag, format: false
  get "data_quality", to: "data_quality#index", as: :data_quality
  get "reconciliation", to: "reconciliation#index", as: :reconciliation

  get "assets/#{LlmCostTracker::Assets::STYLESHEET_FILENAME}",
      to: "assets#stylesheet", as: :stylesheet
end
