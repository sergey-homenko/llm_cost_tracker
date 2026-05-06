# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class TagKeyExplorer
      DEFAULT_LIMIT = 100

      class << self
        def call(scope: LlmCostTracker::Call.all, limit: DEFAULT_LIMIT)
          new(scope: scope, limit: limit).rows
        end
      end

      def initialize(scope:, limit:)
        @scope = scope
        @connection = LlmCostTracker::Call.connection
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

      def build_sql
        tags_table = LlmCostTracker::CallTag.quoted_table_name

        <<~SQL.squish
          SELECT t.#{key_column} AS #{key_column},
                 COUNT(*) AS calls_count,
                 COUNT(DISTINCT t.#{value_column}) AS distinct_values
          FROM (#{scope.to_sql}) AS sub
          INNER JOIN #{tags_table} t ON t.llm_cost_tracker_call_id = sub.id
          GROUP BY t.#{key_column}
          ORDER BY calls_count DESC
          LIMIT #{limit}
        SQL
      end

      def key_column
        connection.quote_column_name("key")
      end

      def value_column
        connection.quote_column_name("value")
      end
    end
  end
end
