# frozen_string_literal: true

module LlmCostTracker
  module Billing
    module UsageSource
      MANUAL = "manual"
      UNKNOWN = "unknown"
      RESPONSE = "response"
      STREAM_FINAL = "stream_final"
      SDK_RESPONSE = "sdk_response"
      SDK_BATCH_RESULT = "sdk_batch_result"
    end
  end
end
