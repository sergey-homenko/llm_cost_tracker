# frozen_string_literal: true

require_relative "../schema/adapter"

module LlmCostTracker
  module Ledger
    class Rollups
      class UpsertSql
        def self.call
          new.call
        end

        def call
          connection = ActiveRecord::Base.connection
          return Arel.sql(mysql_sql) if Ledger::Schema::Adapter.mysql?(connection)
          return Arel.sql(postgres_sql) if Ledger::Schema::Adapter.postgresql?(connection)

          Ledger::Schema::Adapter.ensure_supported!(connection)
        end

        private

        def postgres_sql
          connection = ActiveRecord::Base.connection
          total_cost = connection.quote_column_name("total_cost")
          updated_at = connection.quote_column_name("updated_at")

          "#{total_cost} = #{LlmCostTracker::CallRollup.quoted_table_name}.#{total_cost} + excluded.#{total_cost}, " \
            "#{updated_at} = excluded.#{updated_at}"
        end

        def mysql_sql
          "total_cost = total_cost + VALUES(total_cost), updated_at = VALUES(updated_at)"
        end
      end
    end
  end
end
