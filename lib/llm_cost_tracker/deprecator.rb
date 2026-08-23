# frozen_string_literal: true

require "active_support/deprecation"

module LlmCostTracker
  def self.deprecator
    @deprecator ||= ActiveSupport::Deprecation.new("1.0", "LlmCostTracker")
  end
end
