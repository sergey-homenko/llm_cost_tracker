# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    SpendAnomalyData = Data.define(
      :provider,
      :model,
      :day,
      :latest_spend,
      :baseline_mean,
      :ratio
    )

    class SpendAnomaly
      WINDOW_DAYS = 7

      class << self
        def call(from:, to:, scope: LlmCostTracker::LlmApiCall.all)
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

        alerts.max_by { |item| [item.ratio || 0.0, item.latest_spend] }
      end

      private

      attr_reader :scope, :from, :to

      def alerts
        daily_spend_by_model.each_with_object([]) do |((provider, model), daily_costs), rows|
          latest_spend = daily_costs.fetch(to, 0.0)
          next unless latest_spend.positive?

          baseline_days = ((to - WINDOW_DAYS)...to).map { |day| daily_costs.fetch(day, 0.0) }
          mean = baseline_days.sum / WINDOW_DAYS.to_f
          variance = baseline_days.sum { |value| (value - mean)**2 } / WINDOW_DAYS.to_f
          threshold = mean + (2 * Math.sqrt(variance))
          next unless latest_spend > threshold

          rows << SpendAnomalyData.new(
            provider: provider,
            model: model,
            day: to,
            latest_spend: latest_spend,
            baseline_mean: mean,
            ratio: mean.positive? ? (latest_spend / mean) : nil
          )
        end
      end

      def daily_spend_by_model
        window = (to - WINDOW_DAYS).beginning_of_day..to.end_of_day

        grouped = Hash.new { |hash, key| hash[key] = Hash.new(0.0) }

        scope
          .where(tracked_at: window)
          .pluck(:provider, :model, :tracked_at, :total_cost)
          .each do |provider, model, tracked_at, total_cost|
            next if total_cost.nil?

            grouped[[provider, model]][tracked_at.to_date] += total_cost.to_f
          end

        grouped
      end
    end
  end
end
