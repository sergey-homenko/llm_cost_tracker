# frozen_string_literal: true

module LlmCostTracker
  module ReconciliationHelper
    def attribution_summary(attribution)
      LlmCostTracker::Masking.format_attribution(attribution)
    end
  end
end
