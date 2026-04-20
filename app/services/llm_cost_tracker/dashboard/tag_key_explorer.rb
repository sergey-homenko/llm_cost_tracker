# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    TagKeyRow = Data.define(:key, :calls_count, :distinct_values)

    class TagKeyExplorer
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all)
          new(scope: scope).rows
        end
      end

      def initialize(scope:)
        @scope = scope
        @connection = LlmCostTracker::LlmApiCall.connection
      end

      def rows
        results = @connection.select_all(build_sql).to_a
        results.map do |row|
          TagKeyRow.new(
            key: row["key"].to_s,
            calls_count: row["calls_count"].to_i,
            distinct_values: row["distinct_values"].to_i
          )
        end
      rescue StandardError => e
        LlmCostTracker::Logging.warn("Tag key discovery failed (#{connection.adapter_name}): #{e.class}: #{e.message}")
        []
      end

      private

      attr_reader :scope, :connection

      def subquery
        scope.to_sql
      end

      def build_sql
        case connection.adapter_name
        when /postgres/i then postgresql_sql
        when /mysql/i    then mysql_sql
        else                  sqlite_sql
        end
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
        SQL
      end

      def sqlite_sql
        <<~SQL.squish
          SELECT je.key AS key,
                 COUNT(*) AS calls_count,
                 COUNT(DISTINCT je.value) AS distinct_values
          FROM (#{subquery}) AS sub,
               json_each(sub.tags) AS je
          WHERE sub.tags IS NOT NULL
            AND sub.tags != '{}'
            AND sub.tags != ''
          GROUP BY je.key
          ORDER BY calls_count DESC
        SQL
      end
    end
  end
end
