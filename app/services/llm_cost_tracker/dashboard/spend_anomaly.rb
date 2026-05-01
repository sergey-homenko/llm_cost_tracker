# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class SpendAnomaly
      WINDOW_DAYS = 7

      class << self
        def call(from:, to:, scope: LlmCostTracker::Ledger::Call.all)
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
        window_days = WINDOW_DAYS.to_f
        daily_spend_by_model.each_with_object([]) do |((provider, model), daily_costs), rows|
          latest_spend = daily_costs.fetch(to, 0.0)
          next unless latest_spend.positive?

          baseline_days = ((to - WINDOW_DAYS)...to).map { |day| daily_costs.fetch(day, 0.0) }
          mean = baseline_days.sum / window_days
          variance = baseline_days.sum { |value| (value - mean)**2 } / window_days
          threshold = mean + (2 * Math.sqrt(variance))
          next unless latest_spend > threshold

          rows << {
            provider: provider,
            model: model,
            day: to,
            latest_spend: latest_spend,
            baseline_mean: mean,
            ratio: mean.positive? ? (latest_spend / mean) : nil
          }
        end
      end

      def daily_spend_by_model
        window = (to - WINDOW_DAYS).beginning_of_day..to.end_of_day

        grouped = Hash.new { |hash, key| hash[key] = Hash.new(0.0) }

        scope
          .where(tracked_at: window)
          .where.not(total_cost: nil)
          .group(:provider, :model)
          .group_by_period(:day)
          .sum(:total_cost)
          .each do |(provider, model, day), total_cost|
            grouped[[provider, model]][Date.iso8601(day.to_s)] += total_cost.to_f
          end

        grouped
      end
    end
  end
end
