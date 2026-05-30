# frozen_string_literal: true

module LlmCostTracker
  module Logging
    TAG = "LlmCostTracker"

    class << self
      def debug(message) = Rails.logger.tagged(TAG).debug(message)

      def warn(message) = Rails.logger.tagged(TAG).warn(message)
    end
  end
end
