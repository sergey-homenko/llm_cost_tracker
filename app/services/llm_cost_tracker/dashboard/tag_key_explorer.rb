# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TagKeyExplorer
      DEFAULT_LIMIT = 100

      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all, limit: DEFAULT_LIMIT)
          new(scope: scope, limit: limit).rows
        end
      end

      def initialize(scope:, limit:)
        @scope = scope
        @connection = LlmCostTracker::Ledger::Call.connection
        limit = limit.to_i
        @limit = limit.positive? ? [limit, DEFAULT_LIMIT].min : DEFAULT_LIMIT
      end

      def rows
        scope.klass.find_by_sql(build_sql)
      rescue StandardError => e
        LlmCostTracker::Logging.warn("Tag key discovery failed (#{connection.adapter_name}): #{e.class}: #{e.message}")
        []
      end

      private

      attr_reader :scope, :connection, :limit

      def subquery
        scope.to_sql
      end

      def build_sql
        return postgresql_sql if Ledger::Schema::Adapter.postgresql?(connection)
        return mysql_sql if Ledger::Schema::Adapter.mysql?(connection)

        Ledger::Schema::Adapter.ensure_supported!(connection)
      end

      def mysql_sql
        <<~SQL.squish
          SELECT jt.key AS key,
                 COUNT(*) AS calls_count,
                 COUNT(DISTINCT JSON_UNQUOTE(JSON_EXTRACT(sub.tags, CONCAT('$.', JSON_QUOTE(jt.key))))) AS distinct_values
          FROM (#{subquery}) AS sub
          JOIN JSON_TABLE(
            COALESCE(JSON_KEYS(sub.tags), JSON_ARRAY()),
            '$[*]' COLUMNS(
              key VARCHAR(255) PATH '$'
            )
          ) AS jt
          WHERE sub.tags IS NOT NULL
            AND sub.tags != ''
          GROUP BY jt.key
          ORDER BY calls_count DESC
          LIMIT #{limit}
        SQL
      end

      def postgresql_sql
        <<~SQL.squish
          SELECT key,
                 COUNT(*) AS calls_count,
                 COUNT(DISTINCT (sub.tags::jsonb)->>key) AS distinct_values
          FROM (#{subquery}) AS sub,
               jsonb_object_keys(sub.tags::jsonb) AS key
          WHERE sub.tags IS NOT NULL
            AND sub.tags::jsonb <> '{}'::jsonb
          GROUP BY key
          ORDER BY calls_count DESC
          LIMIT #{limit}
        SQL
      end
    end
  end
end
