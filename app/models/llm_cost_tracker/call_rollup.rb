# frozen_string_literal: true

module LlmCostTracker
  class CallRollup < ActiveRecord::Base
    class << self
      def increment_all(rows)
        upsert_all(rows, on_duplicate: increment_on_duplicate, record_timestamps: true, unique_by: increment_unique_by)
      end

      def decrement(buckets)
        now = Time.now.utc
        buckets.each do |(period, period_start, currency, provider), amount|
          where(period: period, period_start: period_start, currency: currency, provider: provider)
            .update_all(["total_cost = GREATEST(0, total_cost - ?), updated_at = ?", amount, now])
        end
      end

      private

      def increment_on_duplicate
        return Arel.sql(mysql_increment_sql) if Ledger::Schema::Adapter.mysql?(connection)
        return Arel.sql(postgres_increment_sql) if Ledger::Schema::Adapter.postgresql?(connection)

        Ledger::Schema::Adapter.ensure_supported!(connection)
      end

      def postgres_increment_sql
        total = connection.quote_column_name("total_cost")
        updated = connection.quote_column_name("updated_at")
        "#{total} = #{quoted_table_name}.#{total} + excluded.#{total}, #{updated} = excluded.#{updated}"
      end

      def mysql_increment_sql
        "total_cost = total_cost + VALUES(total_cost), updated_at = VALUES(updated_at)"
      end

      def increment_unique_by
        return unless connection.supports_insert_conflict_target?

        %i[period period_start currency provider]
      end
    end
  end
end
