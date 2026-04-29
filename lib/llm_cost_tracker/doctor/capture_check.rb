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
        unless config.enabled
          return check_class.new(:warn, "capture", "tracking is disabled; set config.enabled = true to record calls")
        end

        if config.instrumented_integrations.any?
          return check_class.new(
            :ok,
            "capture",
            "SDK integrations enabled: #{config.instrumented_integrations.join(', ')}"
          )
        end

        check_class.new(
          :ok,
          "capture",
          "no SDK integrations enabled; Faraday middleware and manual capture remain available"
        )
      end

      private

      attr_reader :check_class
    end
  end
end
