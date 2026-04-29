# frozen_string_literal: true

module LlmCostTracker
  module ActiveRecordAdapter
    MYSQL_ADAPTERS = %w[
      ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter
      ActiveRecord::ConnectionAdapters::Mysql2Adapter
      ActiveRecord::ConnectionAdapters::TrilogyAdapter
    ].freeze
    POSTGRESQL_ADAPTERS = %w[
      ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
    ].freeze
    SQLITE_ADAPTERS = %w[
      ActiveRecord::ConnectionAdapters::SQLite3Adapter
    ].freeze
    MYSQL_PATTERN = /mysql|trilogy|mariadb/i
    POSTGRESQL_PATTERN = /postgres/i
    SQLITE_PATTERN = /sqlite/i

    class << self
      def mysql?(value) = adapter_instance?(value, MYSQL_ADAPTERS) || adapter_name(value).match?(MYSQL_PATTERN)

      def postgresql?(value)
        adapter_instance?(value, POSTGRESQL_ADAPTERS) || adapter_name(value).match?(POSTGRESQL_PATTERN)
      end

      def sqlite?(value) = adapter_instance?(value, SQLITE_ADAPTERS) || adapter_name(value).match?(SQLITE_PATTERN)

      private

      def adapter_instance?(value, class_names)
        class_names.any? do |class_name|
          adapter_class = constantize(class_name)
          adapter_class && value.is_a?(adapter_class)
        end
      end

      def constantize(name)
        name.split("::").reduce(Object) { |namespace, part| namespace.const_get(part, false) }
      rescue NameError
        nil
      end

      def adapter_name(value)
        value.respond_to?(:adapter_name) ? value.adapter_name.to_s : value.to_s
      end
    end
  end
end
