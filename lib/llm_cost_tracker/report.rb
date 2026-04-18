# frozen_string_literal: true

require_relative "report_data"
require_relative "report_formatter"

module LlmCostTracker
  class Report
    DEFAULT_DAYS = ReportData::DEFAULT_DAYS

    class << self
      # Render a terminal-friendly cost report from ActiveRecord storage.
      #
      # @param days [Integer] Number of trailing days to include.
      # @param now [Time] Report end time.
      # @return [String]
      def generate(days: DEFAULT_DAYS, now: Time.now.utc)
        ReportFormatter.new(data(days: days, now: now)).to_s
      rescue LoadError => e
        "Unable to build LLM cost report: ActiveRecord storage is unavailable (#{e.message})"
      rescue StandardError => e
        "Unable to build LLM cost report: #{e.class}: #{e.message}"
      end

      def data(days: DEFAULT_DAYS, now: Time.now.utc)
        ReportData.build(days: days, now: now)
      end
    end
  end
end
