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

      def self.parse(params, key)
        value = LlmCostTracker::ParameterHash.with_indifferent_access(params)[key].to_s.strip
        return nil if value.empty?

        Date.iso8601(value)
      rescue ArgumentError
        nil
      end

      def self.validate!(from:, to:)
        return if from.nil? || to.nil?

        raise InvalidFilterError, "from date must be on or before to date" if from > to
        return if ((to - from).to_i + 1) <= MAX_DAYS

        raise InvalidFilterError, "date range cannot exceed #{MAX_DAYS} days"
      end

      def initialize(params:, today:)
        @params = LlmCostTracker::ParameterHash.with_indifferent_access(params)
        @today = today
        @to = self.class.parse(params, :to) || today
        @from = self.class.parse(params, :from) || (@to - (DEFAULT_DAYS - 1))
        self.class.validate!(from: @from, to: @to)
        freeze
      end

      private

      attr_reader :params, :today
    end
  end
end
