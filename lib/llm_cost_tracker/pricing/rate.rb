# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    RATE_BASIS_QUANTITIES = {
      "per_million_tokens" => 1_000_000,
      "per_million_characters" => 1_000_000,
      "per_request" => 1,
      "per_1k_requests" => 1_000,
      "per_session" => 1,
      "per_hour" => 1,
      "per_minute" => 1
    }.freeze

    Rate = Data.define(:amount, :quantity, :currency, :source, :source_key, :source_version)
  end
end
