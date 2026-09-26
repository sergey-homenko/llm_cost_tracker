# frozen_string_literal: true

require_relative "../../errors"

module LlmCostTracker
  module Ledger
    module Schema
      module Adapter
        MYSQL_ADAPTERS = %w[
          ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter
        ].freeze
        POSTGRESQL_ADAPTERS = %w[
          ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
        ].freeze
        MYSQL_PATTERN = /mysql|trilogy|mariadb/i
        POSTGRESQL_PATTERN = /postgres/i

        class << self
          def mysql?(value)
            adapter_instance?(value, MYSQL_ADAPTERS) || adapter_name(value).match?(MYSQL_PATTERN)
          end

          def postgresql?(value)
            adapter_instance?(value, POSTGRESQL_ADAPTERS) || adapter_name(value).match?(POSTGRESQL_PATTERN)
          end

          def ensure_supported!(value)
            return if mysql?(value) || postgresql?(value)

            raise Error, "Unsupported database adapter: #{adapter_name(value)}. Use PostgreSQL or MySQL."
          end

          PG_PERIOD_FORMATS = { day: "YYYY-MM-DD", month: "YYYY-MM" }.freeze
          MYSQL_PERIOD_FORMATS = { day: "%Y-%m-%d", month: "%Y-%m" }.freeze
          private_constant :PG_PERIOD_FORMATS, :MYSQL_PERIOD_FORMATS

          def period_bucket_sql(connection, period, column, time_zone: nil)
            period = period.to_sym
            zone = time_zone&.tzinfo&.name
            if postgresql?(connection)
              if zone && postgresql_zone?(connection, zone)
                column = "(#{column}::timestamp AT TIME ZONE 'UTC') AT TIME ZONE '#{zone}'"
              end
              "TO_CHAR(DATE_TRUNC('#{period}', #{column}), '#{PG_PERIOD_FORMATS.fetch(period)}')"
            elsif mysql?(connection)
              column = "COALESCE(CONVERT_TZ(#{column}, '+00:00', '#{zone}'), #{column})" if zone
              "DATE_FORMAT(#{column}, '#{MYSQL_PERIOD_FORMATS.fetch(period)}')"
            else
              ensure_supported!(connection)
            end
          rescue KeyError
            raise ArgumentError, "invalid period: #{period.inspect}"
          end

          private

          def postgresql_zone?(connection, zone)
            @postgresql_zones ||= {}
            @postgresql_zones.fetch(zone) do
              sql = "SELECT 1 FROM pg_timezone_names WHERE name = #{connection.quote(zone)}"
              @postgresql_zones[zone] = !connection.select_value(sql).nil?
            end
          end

          def adapter_instance?(value, class_names)
            class_names.any? do |class_name|
              adapter_class = class_name.safe_constantize
              adapter_class && value.is_a?(adapter_class)
            end
          end

          def adapter_name(value)
            value.try(:adapter_name).presence || value.to_s
          end
        end
      end
    end
  end
end
