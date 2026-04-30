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
