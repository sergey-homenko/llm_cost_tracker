# frozen_string_literal: true

require_relative "../../errors"

module LlmCostTracker
  module Ledger
    module Schema
      module Adapter
        MYSQL_ADAPTERS = %w[
          ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter
          ActiveRecord::ConnectionAdapters::Mysql2Adapter
          ActiveRecord::ConnectionAdapters::TrilogyAdapter
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

          def json_extract(connection, column, key)
            if postgresql?(connection)
              "#{column}->>'#{key}'"
            else
              "JSON_UNQUOTE(JSON_EXTRACT(#{column}, '$.#{key}'))"
            end
          end

          def json_extract_param(connection, column)
            if postgresql?(connection)
              "#{column}->>?"
            else
              "JSON_UNQUOTE(JSON_EXTRACT(#{column}, ?))"
            end
          end

          def json_path_param(connection, key)
            postgresql?(connection) ? key : "$.#{key}"
          end

          def json_null_sql(connection, column, key)
            if postgresql?(connection)
              "#{column}->>'#{key}' IS NULL"
            else
              extract = "JSON_EXTRACT(#{column}, '$.#{key}')"
              "#{extract} IS NULL OR JSON_TYPE(#{extract}) = 'NULL'"
            end
          end

          def json_present_sql(connection, column, key)
            if postgresql?(connection)
              "#{column}->>'#{key}' IS NOT NULL"
            else
              extract = "JSON_EXTRACT(#{column}, '$.#{key}')"
              "#{extract} IS NOT NULL AND JSON_TYPE(#{extract}) <> 'NULL'"
            end
          end

          def apply_json_contains(connection, relation, column, criteria)
            if postgresql?(connection)
              relation.where("#{column} @> ?::jsonb", criteria.to_json)
            else
              criteria.inject(relation) do |chain, (key, value)|
                chain.where("#{json_extract_param(connection, column)} = ?",
                            json_path_param(connection, key), value.to_s)
              end
            end
          end

          PG_PERIOD_FORMATS = { day: "YYYY-MM-DD", month: "YYYY-MM" }.freeze
          MYSQL_PERIOD_FORMATS = { day: "%Y-%m-%d", month: "%Y-%m" }.freeze
          private_constant :PG_PERIOD_FORMATS, :MYSQL_PERIOD_FORMATS

          def date_truncated_sql(connection, period, column)
            period = period.to_sym
            if postgresql?(connection)
              "TO_CHAR(DATE_TRUNC('#{period}', #{column}), '#{PG_PERIOD_FORMATS.fetch(period)}')"
            elsif mysql?(connection)
              "DATE_FORMAT(#{column}, '#{MYSQL_PERIOD_FORMATS.fetch(period)}')"
            else
              ensure_supported!(connection)
            end
          rescue KeyError
            raise ArgumentError, "invalid period: #{period.inspect}"
          end

          private

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
