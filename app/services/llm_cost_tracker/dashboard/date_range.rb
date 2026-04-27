# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class DateRange
      DEFAULT_DAYS = 30
      MAX_DAYS = 366

      attr_reader :from, :to

      def self.call(params:, today: Date.current)
        new(params: params, today: today)
      end

      def initialize(params:, today:)
        @params = LlmCostTracker::ParameterHash.with_indifferent_access(params)
        @today = today
        @to = parse_date(:to) || today
        @from = parse_date(:from) || (@to - (DEFAULT_DAYS - 1))
        validate!
        freeze
      end

      private

      attr_reader :params, :today

      def parse_date(key)
        value = params[key].to_s.strip
        return nil if value.empty?

        Date.iso8601(value)
      rescue ArgumentError
        nil
      end

      def validate!
        raise InvalidFilterError, "from date must be on or before to date" if from > to
        return if ((to - from).to_i + 1) <= MAX_DAYS

        raise InvalidFilterError, "date range cannot exceed #{MAX_DAYS} days"
      end
    end
  end
end
