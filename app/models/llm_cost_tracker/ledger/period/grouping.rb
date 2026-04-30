# frozen_string_literal: true

require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Ledger
    module Period
      module Grouping
        PERIOD_FORMATS = {
          day: {
            postgres: "YYYY-MM-DD",
            mysql: "%Y-%m-%d"
          },
          month: {
            postgres: "YYYY-MM",
            mysql: "%Y-%m"
          }
        }.freeze

        private_constant :PERIOD_FORMATS

        def group_by_period(period, column: :tracked_at)
          group(Arel.sql(period_group_expression(period, column: column)))
        end

        def daily_costs(days: 30)
          where(tracked_at: days.days.ago..)
            .group_by_period(:day)
            .sum(:total_cost)
        end

        private

        def period_group_expression(period, column:)
          period = validated_period(period)
          column = period_column_expression(column)
          formats = PERIOD_FORMATS.fetch(period)

          if Ledger::Schema::Adapter.postgresql?(connection)
            postgres_period_expression(period, column, formats)
          elsif Ledger::Schema::Adapter.mysql?(connection)
            "DATE_FORMAT(#{column}, #{connection.quote(formats.fetch(:mysql))})"
          else
            Ledger::Schema::Adapter.ensure_supported!(connection)
          end
        end

        def postgres_period_expression(period, column, formats)
          "TO_CHAR(" \
            "DATE_TRUNC(#{connection.quote(period.to_s)}, #{column}), " \
            "#{connection.quote(formats.fetch(:postgres))}" \
            ")"
        end

        def validated_period(period)
          normalized_period = period.try(:to_sym)
          return normalized_period if PERIOD_FORMATS.key?(normalized_period)

          raise ArgumentError, "invalid period: #{period.inspect}"
        end

        def period_column_expression(column)
          column = column.to_s
          return "#{quoted_table_name}.#{connection.quote_column_name(column)}" if column_names.include?(column)

          raise ArgumentError, "invalid period column: #{column.inspect}"
        end
      end
    end
  end
end
