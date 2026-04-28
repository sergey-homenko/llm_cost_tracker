# frozen_string_literal: true

module LlmCostTracker
  class Doctor
    class CaptureCheck
      def self.call(check_class)
        new(check_class).call
      end

      def initialize(check_class)
        @check_class = check_class
      end

      def call
        config = LlmCostTracker.configuration
        return disabled_check unless config.enabled
        return integrations_check(config.instrumented_integrations) if config.instrumented_integrations.any?

        check(:ok, "no SDK integrations enabled; Faraday middleware and manual capture remain available")
      end

      private

      attr_reader :check_class

      def disabled_check
        check(:warn, "tracking is disabled; set config.enabled = true to record calls")
      end

      def integrations_check(integrations)
        check(:ok, "SDK integrations enabled: #{integrations.join(', ')}")
      end

      def check(status, message)
        check_class.new(status, "capture", message)
      end
    end
  end
end
