# frozen_string_literal: true

require_relative "report_data"
require_relative "report_formatter"

module LlmCostTracker
  class Report
    DEFAULT_DAYS = ReportData::DEFAULT_DAYS

    class << self
      def generate(days: DEFAULT_DAYS, now: Time.now.utc, tag_breakdowns: nil)
        report_data = ReportData.build(
          days: days,
          now: now,
          tag_breakdowns: tag_breakdowns,
          breakdown_limit: ReportFormatter::TOP_LIMIT
        )

        ReportFormatter.new(report_data).to_s
      rescue LoadError => e
        "Unable to build LLM cost report: ActiveRecord storage is unavailable (#{e.message})"
      rescue StandardError => e
        "Unable to build LLM cost report: #{e.class}: #{e.message}"
      end

      def data(days: DEFAULT_DAYS, now: Time.now.utc, tag_breakdowns: nil)
        ReportData.build(days: days, now: now, tag_breakdowns: tag_breakdowns)
      end
    end
  end
end
