# frozen_string_literal: true

LlmCostTracker::Engine.routes.draw do
  root "dashboard#index"
  resources :calls, only: %i[index show], constraints: { id: /\d+/ }, defaults: { format: :html }
  resources :models, only: :index
  resources :tags, only: %i[index show], param: :key, format: false
  get "data_quality", to: "data_quality#index", as: :data_quality
  get "reconciliation", to: "reconciliation#index", as: :reconciliation
  post "reconciliation/import", to: "reconciliation#trigger_import", as: :reconciliation_import

  get "assets/#{LlmCostTracker::Assets::STYLESHEET_FILENAME}",
      to: "assets#stylesheet", as: :stylesheet
end
