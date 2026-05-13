# frozen_string_literal: true

require_relative "report/data"
require_relative "report/formatter"

module LlmCostTracker
  class Report
    class << self
      def generate(days: Data::DEFAULT_DAYS, now: Time.now.utc, tag_breakdowns: nil)
        report_data = Data.build(
          days: days,
          now: now,
          tag_breakdowns: tag_breakdowns,
          breakdown_limit: Formatter::TOP_LIMIT
        )

        Formatter.new(report_data).to_s
      rescue LoadError => e
        "Unable to build LLM cost report: ActiveRecord storage is unavailable (#{e.message})"
      end
    end
  end
end
