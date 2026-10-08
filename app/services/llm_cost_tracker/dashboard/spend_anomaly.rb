# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class SpendAnomaly
      WINDOW_DAYS = 7

      class << self
        def call(from:, to:, scope: LlmCostTracker::Call.all)
          new(scope: scope, from: from, to: to).alert
        end
      end

      def initialize(scope:, from:, to:)
        @scope = scope
        @from = from.to_date
        @to = to.to_date
      end

      def alert
        return nil if from > (to - WINDOW_DAYS)

        alerts.max_by { |item| [item.fetch(:ratio) || 0.0, item.fetch(:latest_spend)] }
      end

      private

      attr_reader :scope, :from, :to

      def alerts
        daily_spend_by_model.filter_map do |(provider, model), daily_costs|
          latest_spend = daily_costs.fetch(to, 0.0)
          next unless latest_spend.positive?

          mean, deviation = baseline(daily_costs)
          next unless latest_spend > mean + (2 * deviation)

          {
            provider: provider,
            model: model,
            day: to,
            latest_spend: latest_spend,
            baseline_mean: mean,
            ratio: mean.positive? ? (latest_spend / mean) : nil
          }
        end
      end

      def baseline(daily_costs)
        days = ((to - WINDOW_DAYS)...to).map { |day| daily_costs.fetch(day, 0.0) }
        mean = days.sum / WINDOW_DAYS.to_f
        variance = days.sum { |value| (value - mean)**2 } / WINDOW_DAYS.to_f
        [mean, Math.sqrt(variance)]
      end

      def daily_spend_by_model
        daily_costs = Hash.new { |hash, key| hash[key] = Hash.new(0.0) }
        daily_totals.each do |(provider, model, day), total_cost|
          daily_costs[[provider, model]][Date.iso8601(day.to_s)] += total_cost.to_f
        end
        daily_costs
      end

      def daily_totals
        scope
          .where(tracked_at: (to - WINDOW_DAYS).beginning_of_day..to.end_of_day)
          .where.not(total_cost: nil)
          .group(:provider, :model)
          .group_by_period(:day, time_zone: Time.zone)
          .sum(:total_cost)
      end
    end
  end
end
