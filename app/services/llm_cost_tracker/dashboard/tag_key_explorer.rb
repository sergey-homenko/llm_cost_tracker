# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Dashboard
    TagKeyRow = Data.define(:key, :calls_count, :distinct_values)

    class TagKeyExplorer
      RUBY_FALLBACK_LIMIT = 50_000

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
        sql = build_sql
        return ruby_fallback_rows if sql.nil?

        results = @connection.select_all(sql).to_a
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
        when /mysql/i    then nil
        else                  sqlite_sql
        end
      end

      def ruby_fallback_rows
        calls_counter = Hash.new(0)
        values_per_key = Hash.new { |h, k| h[k] = Set.new }

        scope.limit(RUBY_FALLBACK_LIMIT).pluck(:tags).each do |raw|
          tags = parse_tags(raw)
          next if tags.empty?

          tags.each do |key, value|
            calls_counter[key] += 1
            values_per_key[key] << value.to_s
          end
        end

        calls_counter
          .sort_by { |_, count| -count }
          .map do |key, count|
            TagKeyRow.new(key: key.to_s, calls_count: count, distinct_values: values_per_key[key].size)
          end
      rescue StandardError => e
        LlmCostTracker::Logging.warn("Tag key Ruby fallback failed: #{e.class}: #{e.message}")
        []
      end

      def parse_tags(raw)
        case raw
        when Hash then raw
        when String
          return {} if raw.strip.empty?

          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : {}
        else
          {}
        end
      rescue JSON::ParserError
        {}
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
