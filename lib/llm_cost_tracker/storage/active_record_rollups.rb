# frozen_string_literal: true

module LlmCostTracker
  module Storage
    class ActiveRecordRollups
      PERIODS = {
        monthly: { table: "llm_cost_tracker_monthly_totals", column: :month_start },
        daily:   { table: "llm_cost_tracker_daily_totals", column: :day }
      }.freeze

      class << self
        def reset!
          remove_instance_variable(:@totals_enabled) if instance_variable_defined?(:@totals_enabled)
        end

        def increment!(event)
          return unless event.cost&.total_cost

          PERIODS.each_key { |period| increment_total(period, event) }
        end

        def monthly_total(time: Time.now.utc)
          period_total(:monthly, time)
        end

        def daily_total(time: Time.now.utc)
          period_total(:daily, time)
        end

        private

        def period_total(period, time)
          if totals_enabled?(period)
            model_for(period).where(column_for(period) => bucket_for(period, time)).pick(:total_cost).to_f
          else
            LlmCostTracker::LlmApiCall
              .where(tracked_at: range_start_for(period, time)..time)
              .sum(:total_cost)
              .to_f
          end
        end

        def increment_total(period, event)
          return unless totals_enabled?(period)

          model = model_for(period)
          model.upsert_all(
            [
              {
                column_for(period) => bucket_for(period, event.tracked_at),
                total_cost: event.cost.total_cost
              }
            ],
            on_duplicate: total_upsert_sql(model),
            record_timestamps: true,
            unique_by: unique_by(model, column_for(period))
          )
        end

        def totals_enabled?(period)
          @totals_enabled ||= {}
          return @totals_enabled[period] if @totals_enabled.key?(period)

          @totals_enabled[period] =
            LlmCostTracker::LlmApiCall.connection.data_source_exists?(table_for(period))
        end

        def table_for(period)
          PERIODS.fetch(period).fetch(:table)
        end

        def column_for(period)
          PERIODS.fetch(period).fetch(:column)
        end

        def model_for(period)
          case period
          when :monthly
            require_relative "../monthly_total" unless defined?(LlmCostTracker::MonthlyTotal)

            LlmCostTracker::MonthlyTotal
          when :daily
            require_relative "../daily_total" unless defined?(LlmCostTracker::DailyTotal)

            LlmCostTracker::DailyTotal
          end
        end

        def range_start_for(period, time)
          case period
          when :monthly then time.beginning_of_month
          when :daily   then time.beginning_of_day
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
