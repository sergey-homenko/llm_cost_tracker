# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    SourceResult = Data.define(:prices, :missing_models, :source_version)
  end
end
