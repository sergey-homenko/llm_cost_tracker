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
        return Check.new(:error, "prices", "#{path} does not exist; #{REFRESH_COMMAND}") unless File.exist?(path)

        count = Pricing::Registry.file_prices(path).size
        status, freshness = freshness(Pricing::Registry.file_metadata(path))
        Check.new(status, "prices", "loaded #{count} models from #{path}; #{freshness}")
      rescue LlmCostTracker::Error => e
        Check.new(:error, "prices", e.message)
      end

      private

      def bundled_check
        updated_at = Pricing::Registry.metadata.fetch("updated_at", "unknown")
        Check.new(
          :warn,
          "prices",
          "using bundled prices updated_at=#{updated_at}; " \
          "commit a prices_file (config.pricing.file) for production releases"
        )
      end

      def freshness(metadata)
        updated_at = metadata["updated_at"] || metadata[:updated_at]
        return [:warn, "metadata.updated_at missing; #{REFRESH_COMMAND}"] unless updated_at

        reason = staleness(updated_at)
        reason ? [:warn, "#{reason}; #{REFRESH_COMMAND}"] : [:ok, "updated_at=#{updated_at}"]
      rescue Date::Error
        [:warn, "metadata.updated_at=#{updated_at.inspect} is invalid; #{REFRESH_COMMAND}"]
      end

      def staleness(updated_at)
        file_date = Date.iso8601(updated_at.to_s)
        if (Date.today - file_date).to_i > STALE_AFTER_DAYS
          return "updated_at=#{updated_at} is older than #{STALE_AFTER_DAYS} days"
        end

        bundled_at = Pricing::Registry.metadata["updated_at"]
        return unless bundled_at && file_date < Date.iso8601(bundled_at.to_s)

        "updated_at=#{updated_at} is older than the bundled prices (#{bundled_at})"
      end
    end
  end
end
