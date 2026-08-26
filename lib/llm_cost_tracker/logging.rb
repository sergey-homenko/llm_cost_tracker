# frozen_string_literal: true

module LlmCostTracker
  module Logging
    class << self
      def debug(message) = Rails.logger.debug(prefixed(message))

      def warn(message) = Rails.logger.warn(prefixed(message))

      private

      def prefixed(message) = "[#{LlmCostTracker.name}] #{message}"
    end
  end
end
