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
        logger = Rails.logger

        if logger
          logger.try(level, message)
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
    end
  end
end
