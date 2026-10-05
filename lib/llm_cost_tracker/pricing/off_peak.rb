# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module OffPeak
      HOURS = /\A((?:[01]\d|2[0-3]):[0-5]\d)-((?:[01]\d|2[0-3]):[0-5]\d|24:00)\z/
      KEYS = %w[hours_utc weekdays].freeze

      class << self
        def windows(value, label:)
          windows = Array(value).map { |window| window.is_a?(Hash) ? window.transform_keys(&:to_s) : {} }
          unless value.is_a?(Array) && list?(windows) { |window| window?(window) }
            raise ArgumentError,
                  "#{label} must be a list of windows like " \
                  '{"weekdays" => [1, 2, 3, 4, 5], "hours_utc" => ["00:00-01:00", "10:00-24:00"]} ' \
                  "(ISO weekdays, UTC hours, start inclusive, end exclusive), got #{value.inspect}"
          end

          windows.map(&:freeze).freeze
        end

        def cover?(windows, at)
          time = at.getutc
          weekday = time.wday.zero? ? 7 : time.wday
          minute = (time.hour * 60) + time.min
          windows.any? do |window|
            window["weekdays"].include?(weekday) &&
              window["hours_utc"].any? { |hours| minutes(hours).then { |from, to| minute >= from && minute < to } }
          end
        end

        private

        def window?(window)
          weekdays, hours = window.values_at("weekdays", "hours_utc")
          window.keys.sort == KEYS && list?(weekdays) { |day| day.is_a?(Integer) && day.between?(1, 7) } &&
            list?(hours) { |range| minutes(range)&.then { |from, to| from < to } }
        end

        def list?(value, &)
          value.is_a?(Array) && value.any? && value.all?(&)
        end

        def minutes(range)
          range.to_s.match(HOURS)&.captures&.map { |clock| (clock[0, 2].to_i * 60) + clock[3, 2].to_i }
        end
      end
    end
  end
end
