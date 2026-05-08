# frozen_string_literal: true

module LlmCostTracker
  module ReconciliationHelper
    def attribution_summary(attribution)
      LlmCostTracker::Reconciliation::Masking.format_attribution(attribution)
    end

    def mask_secret(value)
      LlmCostTracker::Reconciliation::Masking.mask_value(:provider_api_key_id, value)
    end
  end
end
