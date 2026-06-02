# frozen_string_literal: true

module LlmCostTracker
  class CallRollup < ActiveRecord::Base
    def self.decrement(buckets)
      now = Time.now.utc
      buckets.each do |(period, period_start, currency, provider), amount|
        where(period: period, period_start: period_start, currency: currency, provider: provider)
          .update_all(["total_cost = GREATEST(0, total_cost - ?), updated_at = ?", amount, now])
      end
    end
  end
end
