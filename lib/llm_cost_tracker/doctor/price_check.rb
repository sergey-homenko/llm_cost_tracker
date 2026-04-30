# frozen_string_literal: true

require "date"

module LlmCostTracker
  class Doctor
    class PriceCheck
      STALE_AFTER_DAYS = 30
      REFRESH_COMMAND = "run bin/rails llm_cost_tracker:prices:refresh"

      def self.call(check_class)
        new(check_class).call
      end

      def initialize(check_class)
        @check_class = check_class
      end

      def call
        path = LlmCostTracker.configuration.prices_file
        return bundled_check unless path

        count = LlmCostTracker::PriceRegistry.file_prices(path).size
        metadata = LlmCostTracker::PriceRegistry.file_metadata(path)
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
        check_class.new(:error, "prices", e.message)
      end

      private

      attr_reader :check_class

      def bundled_check
        updated_at = LlmCostTracker::PriceRegistry.metadata.fetch("updated_at", "unknown")
        check_class.new(
          :warn,
          "prices",
          "using bundled prices updated_at=#{updated_at}; configure prices_file for production"
        )
      end

      def configured_check(status, path, count, freshness)
        check_class.new(status, "prices", "loaded #{count} models from #{path}; #{freshness}")
      end
    end
  end
end
