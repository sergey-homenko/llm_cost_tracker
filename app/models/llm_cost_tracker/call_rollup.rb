# frozen_string_literal: true

module LlmCostTracker
  class CallRollup < ActiveRecord::Base
    class << self
      def increment_all(rows)
        upsert_all(rows, on_duplicate: increment_on_duplicate, record_timestamps: true, unique_by: increment_unique_by)
      end

      DECREMENT_SLICE = 100

      def decrement(buckets)
        now = Time.now.utc
        buckets.each_slice(DECREMENT_SLICE) do |slice|
          where(decrement_scope(slice)).update_all(decrement_assignment(slice, now))
        end
      end

      private

      def decrement_scope(slice)
        rows = Array.new(slice.size, "(?, ?, ?, ?)").join(", ")
        binds = slice.flat_map { |bucket, _| bucket }
        sanitize_sql_array(["(period, period_start, currency, provider) IN (#{rows})", *binds])
      end

      def decrement_assignment(slice, now)
        branches = slice.map { "WHEN period = ? AND period_start = ? AND currency = ? AND provider = ? THEN ?" }
        binds = slice.flat_map { |bucket, amount| [*bucket, amount] }
        sanitize_sql_array(
          ["total_cost = GREATEST(0, total_cost - CASE #{branches.join(' ')} ELSE 0 END), updated_at = ?",
           *binds, now]
        )
      end

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
