# frozen_string_literal: true

require "date"

module LlmCostTracker
  module PriceFreshness
    STALE_AFTER_DAYS = 30

    class << self
      def call(metadata, today: Date.today)
        updated_at = metadata["updated_at"] || metadata[:updated_at]
        return missing unless updated_at

        date = Date.iso8601(updated_at.to_s)
        age_days = (today - date).to_i
        return stale(updated_at) if age_days > STALE_AFTER_DAYS

        [:ok, "updated_at=#{updated_at}"]
      rescue Date::Error
        [:warn, "metadata.updated_at=#{updated_at.inspect} is invalid; run bin/rails llm_cost_tracker:prices:sync"]
      end

      private

      def missing
        [:warn, "metadata.updated_at missing; run bin/rails llm_cost_tracker:prices:sync"]
      end

      def stale(updated_at)
        [
          :warn,
          "updated_at=#{updated_at} is older than #{STALE_AFTER_DAYS} days; " \
          "run bin/rails llm_cost_tracker:prices:sync"
        ]
      end
    end
  end
end
