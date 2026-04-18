# frozen_string_literal: true

module LlmCostTracker
  module Logging
    PREFIX = "[LlmCostTracker]"

    class << self
      def debug(message)
        log(:debug, message)
      end

      def info(message)
        log(:info, message)
      end

      def warn(message)
        log(:warn, message)
      end

      def log(level, message)
        message = prefixed(message)

        if rails_logger
          rails_logger.public_send(level, message)
        else
          Kernel.warn(message)
        end
      end

      private

      def prefixed(message)
        message = message.to_s
        return message if message.start_with?(PREFIX)

        "#{PREFIX} #{message}"
      end

      def rails_logger
        Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      end
    end
  end
end
