# frozen_string_literal: true

require "date"

require_relative "../check"

module LlmCostTracker
  class Doctor
    class PriceCheck
      STALE_AFTER_DAYS = 30
      REFRESH_COMMAND = "refresh the source-controlled prices file with bin/rails llm_cost_tracker:prices:refresh"

      def call
        path = LlmCostTracker.configuration.pricing.file
        return bundled_check unless path

        count = LlmCostTracker::Pricing::Registry.file_prices(path).size
        metadata = LlmCostTracker::Pricing::Registry.file_metadata(path)
        updated_at = metadata["updated_at"] || metadata[:updated_at]
        return configured_check(:warn, path, count, "metadata.updated_at missing; #{REFRESH_COMMAND}") unless updated_at

        age_days = (Date.today - Date.iso8601(updated_at.to_s)).to_i
        if age_days > STALE_AFTER_DAYS
          return configured_check(
            :warn,
            path,
            count,
            "updated_at=#{updated_at} is older than #{STALE_AFTER_DAYS} days; #{REFRESH_COMMAND}"
          )
        end

        configured_check(:ok, path, count, "updated_at=#{updated_at}")
      rescue Date::Error
        configured_check(
          :warn,
          path,
          count,
          "metadata.updated_at=#{updated_at.inspect} is invalid; #{REFRESH_COMMAND}"
        )
      rescue LlmCostTracker::Error => e
        Check.new(:error, "prices", e.message)
      end

      private

      def bundled_check
        updated_at = LlmCostTracker::Pricing::Registry.metadata.fetch("updated_at", "unknown")
        Check.new(
          :warn,
          "prices",
          "using bundled prices updated_at=#{updated_at}; commit a prices_file for production releases"
        )
      end

      def configured_check(status, path, count, freshness)
        Check.new(status, "prices", "loaded #{count} models from #{path}; #{freshness}")
      end
    end
  end
end
