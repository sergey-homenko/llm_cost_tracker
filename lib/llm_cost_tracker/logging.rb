# frozen_string_literal: true

require_relative "redaction"

module LlmCostTracker
  module Logging
    class << self
      def debug(message) = Rails.logger.debug(prefixed(message))

      def warn(message) = Rails.logger.warn(prefixed(message))

      private

      def prefixed(message) = "[#{LlmCostTracker.name}] #{Redaction.text(message)}"
    end
  end
end
