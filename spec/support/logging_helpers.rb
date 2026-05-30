# frozen_string_literal: true

require "logger"
require "stringio"
require "active_support/tagged_logging"

module LlmCostTrackerLoggingHelpers
  def self.tagged_logger(target)
    ActiveSupport::TaggedLogging.new(Logger.new(target))
  end

  def capture_log
    buffer = StringIO.new
    previous = Rails.logger
    Rails.logger = LlmCostTrackerLoggingHelpers.tagged_logger(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = previous
  end
end

RSpec.configure do |config|
  config.include LlmCostTrackerLoggingHelpers
end
