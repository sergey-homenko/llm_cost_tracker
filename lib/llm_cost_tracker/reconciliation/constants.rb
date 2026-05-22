# frozen_string_literal: true

module LlmCostTracker
  module Reconciliation
    DEFAULT_THRESHOLD_PERCENT = 5.0
    INVOICE_FRESHNESS_DAYS = 14
    SOURCE_TO_PROVIDER = {
      "openai" => "openai",
      "openai_usage" => "openai",
      "anthropic" => "anthropic",
      "anthropic_usage" => "anthropic",
      "gemini" => "gemini"
    }.freeze
    BASIS_DIMENSIONS = [
      ["project",   :provider_project_id],
      ["api_key",   :provider_api_key_id],
      ["workspace", :provider_workspace_id],
      ["model",     :model]
    ].freeze
  end
end
