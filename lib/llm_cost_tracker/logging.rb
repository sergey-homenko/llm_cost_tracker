# frozen_string_literal: true

module LlmCostTracker
  module Logging
    class << self
      def debug(message) = tagged.debug(message)

      def warn(message) = tagged.warn(message)

      private

      def tagged
        Rails.logger.tagged(LlmCostTracker.name)
      end
    end
  end
end
