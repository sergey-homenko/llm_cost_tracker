# frozen_string_literal: true

module LlmCostTracker
  module Storage
    class ActiveRecordRollups
      PERIODS = {
        monthly: "month",
        daily:   "day"
      }.freeze

      class << self
        def reset!
          remove_instance_variable(:@period_totals_enabled) if instance_variable_defined?(:@period_totals_enabled)
        end

        def increment!(event)
          return unless event.cost&.total_cost
          return unless period_totals_enabled?

          model = period_total_model
          model.upsert_all(
            period_rows(event),
            on_duplicate: total_upsert_sql(model),
            record_timestamps: true,
            unique_by: unique_by(model, %i[period period_start])
          )
        end

        def monthly_total(time: Time.now.utc)
          period_totals(%i[monthly], time: time).fetch(:monthly)
        end

        def daily_total(time: Time.now.utc)
          period_totals(%i[daily], time: time).fetch(:daily)
        end

        def period_totals(periods, time: Time.now.utc)
          periods = periods.map(&:to_sym).select { |period| PERIODS.key?(period) }
          return {} if periods.empty?

          if period_totals_enabled?
            rollup_period_totals(periods, time)
          else
            periods.to_h { |period| [period, fallback_period_total(period, time)] }
          end
        end

        private

        def period_rows(event)
          PERIODS.map do |period, name|
            {
              period: name,
              period_start: bucket_for(period, event.tracked_at),
              total_cost: event.cost.total_cost
            }
          end
        end

        def rollup_period_totals(periods, time)
          buckets = periods.to_h { |period| [period, bucket_for(period, time)] }
          index = buckets.to_h { |period, bucket| [[PERIODS.fetch(period), bucket], period] }
          totals = periods.to_h { |period| [period, 0.0] }

          period_total_model
            .where(period: periods.map { |period| PERIODS.fetch(period) }, period_start: buckets.values)
            .pluck(:period, :period_start, :total_cost)
            .each do |name, start, total|
              period = index[[name, start.to_date]]
              totals[period] = total.to_f if period
            end

          totals
        end

        def fallback_period_total(period, time)
          LlmCostTracker::LlmApiCall
            .where(tracked_at: range_start_for(period, time)..time)
            .sum(:total_cost)
            .to_f
        end

        def period_totals_enabled?
          return @period_totals_enabled unless @period_totals_enabled.nil?

          @period_totals_enabled =
            LlmCostTracker::LlmApiCall.connection.data_source_exists?("llm_cost_tracker_period_totals")
        end

        def period_total_model
          require_relative "../period_total" unless defined?(LlmCostTracker::PeriodTotal)

          LlmCostTracker::PeriodTotal
        end

        def range_start_for(period, time)
          utc_time = time.to_time.utc

          case period
          when :monthly then utc_time.beginning_of_month
          when :daily   then utc_time.beginning_of_day
          end
        end

        def bucket_for(period, time)
          utc_time = time.to_time.utc

          case period
          when :monthly then utc_time.beginning_of_month.to_date
          when :daily   then utc_time.to_date
          end
        end

        def unique_by(model, column)
          return unless model.connection.supports_insert_conflict_target?

          column
        end

        def total_upsert_sql(model)
          Arel.sql(case model.connection.adapter_name
                   when /mysql/i
                     mysql_upsert_sql(model)
                   else
                     "total_cost = total_cost + excluded.total_cost, updated_at = excluded.updated_at"
                   end)
        end

        def mysql_upsert_sql(model)
          connection = model.connection
          if connection.respond_to?(:supports_insert_raw_alias_syntax?, true) &&
             connection.send(:supports_insert_raw_alias_syntax?)
            values_reference = connection.quote_table_name("#{model.table_name}_values")
            "total_cost = total_cost + #{values_reference}.total_cost, updated_at = #{values_reference}.updated_at"
          else
            "total_cost = total_cost + VALUES(total_cost), updated_at = VALUES(updated_at)"
          end
        end
      end
    end
  end
end
