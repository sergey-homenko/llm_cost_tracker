# frozen_string_literal: true

require_relative "../active_record_adapter"

module LlmCostTracker
  module Storage
    class ActiveRecordRollupUpsertSql
      def self.call(model)
        new(model).call
      end

      def initialize(model)
        @model = model
      end

      def call
        return Arel.sql(mysql_sql) if ActiveRecordAdapter.mysql?(connection)
        return Arel.sql(postgres_sql) if ActiveRecordAdapter.postgresql?(connection)

        Arel.sql("total_cost = total_cost + excluded.total_cost, updated_at = excluded.updated_at")
      end

      private

      attr_reader :model

      def postgres_sql
        total_cost = connection.quote_column_name("total_cost")
        updated_at = connection.quote_column_name("updated_at")

        "#{total_cost} = #{model.quoted_table_name}.#{total_cost} + excluded.#{total_cost}, " \
          "#{updated_at} = excluded.#{updated_at}"
      end

      def mysql_sql
        "total_cost = total_cost + VALUES(total_cost), updated_at = VALUES(updated_at)"
      end

      def connection = model.connection
    end
  end
end
