# frozen_string_literal: true

require_relative "limit"
require_relative "../timing"
require_relative "../ledger/isolation"
require_relative "../ledger/schema/adapter"
require_relative "../ledger/tags/encoding"

module LlmCostTracker
  module Budget
    module PerTag
      COST_COLUMN = "total_cost"
      TIME_COLUMN = "tracked_at"
      WINDOW_STARTS = { daily: :beginning_of_day, weekly: :beginning_of_week, monthly: :beginning_of_month }.freeze
      WINDOW_NEXTS = { daily: :next_day, weekly: :next_week, monthly: :next_month }.freeze
      SLOW_READ_SECONDS = 0.1
      DEFAULT_BACKFILL_BATCH = 5_000

      Rule = Data.define(:key, :value, :windows, :behavior, :on_exceeded) do
        def limit(window)
          Limit.new(budget_type: window,
                    budget: windows.fetch(window),
                    scope: { key: key, value: value },
                    behavior: behavior,
                    on_exceeded: on_exceeded)
        end
      end

      class << self
        def configured
          LlmCostTracker.configuration.budgets.per_tag
        end

        def active?
          return false if configured.empty?
          return true if columns?

          warn_missing_columns
          false
        end

        def blocking?
          configured.each_value.any? { |entry| behavior_for(entry) == :block_requests } && active?
        end

        def rules_for(tags, blocking_only: false)
          return [] unless active?

          normalized = (tags || {}).to_h.transform_keys(&:to_s)
          configured.filter_map do |key, entry|
            value = Ledger::Tags::Encoding.encode(normalized[key])
            next if value.empty?
            next if blocking_only && behavior_for(entry) != :block_requests

            Rule.new(
              key: key,
              value: value,
              windows: entry[:windows],
              behavior: behavior_for(entry),
              on_exceeded: on_exceeded_for(entry)
            )
          end
        end

        def rules_for_events(events)
          events.each_with_object({}) do |event, grouped|
            rules_for(event.tags).each { |rule| (grouped[rule] ||= []) << event }
          end
        end

        def spend(key, value, window, time:)
          spend_by_value(key, [value], window, window_start(window, time)).fetch(value, [0]).first
        end

        def spend_by_value(key, values, window, bucket, upto = nil)
          started_at = Timing.now_monotonic
          aggregates = sum_columns(window, upto)
          totals = Ledger::Isolation.guard(LlmCostTracker::CallTag) do
            pluck_by_exact_value(spend_rows(key, values, window, bucket), values, aggregates).to_h do |value, *sums|
              [value.dup.force_encoding(Encoding::UTF_8), sums.map { |sum| window == :calls ? sum.to_i : sum.to_d }]
            end
          end
          warn_slow_read(key, window, Timing.now_monotonic - started_at)
          totals
        end

        def window_start(window, time)
          WINDOW_STARTS[window]&.then { |start| time.to_time.utc.public_send(start) }
        end

        def backfill(batch_size: DEFAULT_BACKFILL_BATCH)
          return 0 unless columns?

          filled = 0
          loop do
            copied = copy_next_batch(batch_size)
            break if copied.zero?

            filled += copied
          end
          filled
        end

        def columns?
          LlmCostTracker::CallTag.table_exists? &&
            (LlmCostTracker::CallTag.column_names & [COST_COLUMN, TIME_COLUMN]).size == 2
        end

        private

        def sum_columns(window, upto)
          measure = window == :calls ? "1" : COST_COLUMN
          total = "SUM(#{measure})"
          upto_sum = "SUM(CASE WHEN #{TIME_COLUMN} <= ? THEN #{measure} ELSE 0 END)"
          upto_total = upto ? LlmCostTracker::CallTag.sanitize_sql_array([upto_sum, upto]) : total
          [Arel.sql(total), Arel.sql(upto_total)]
        end

        def spend_rows(key, values, window, bucket)
          rows = LlmCostTracker::CallTag.where(key: key, value: values)
          bucket ? rows.where(TIME_COLUMN => window_range(window, bucket)) : rows.where.not(TIME_COLUMN => nil)
        end

        def pluck_by_exact_value(rows, values, aggregates)
          column = :value
          if Ledger::Schema::Adapter.mysql?(LlmCostTracker::CallTag.lease_connection)
            column = Arel.sql("CAST(value AS BINARY)")
            rows = rows.where(column.in(values))
          end
          rows.group(column).pluck(column, *aggregates)
        end

        def window_range(window, bucket)
          bucket...bucket.public_send(WINDOW_NEXTS.fetch(window))
        end

        def copy_next_batch(batch_size)
          ids = LlmCostTracker::CallTag.where(TIME_COLUMN => nil).limit(batch_size).pluck(:id)
          return 0 if ids.empty?

          LlmCostTracker::CallTag.lease_connection.update(copy_sql(ids))
        end

        def copy_sql(ids)
          tags = LlmCostTracker::CallTag.quoted_table_name
          calls = LlmCostTracker::Call.quoted_table_name
          list = ids.join(",")
          return <<~SQL.squish unless Ledger::Schema::Adapter.postgresql?(LlmCostTracker::CallTag.lease_connection)
            UPDATE #{tags} t JOIN #{calls} c ON c.id = t.llm_cost_tracker_call_id
               SET t.#{COST_COLUMN} = c.#{COST_COLUMN}, t.#{TIME_COLUMN} = c.#{TIME_COLUMN}
             WHERE t.id IN (#{list})
          SQL

          <<~SQL.squish
            UPDATE #{tags} AS t
               SET #{COST_COLUMN} = c.#{COST_COLUMN}, #{TIME_COLUMN} = c.#{TIME_COLUMN}
              FROM #{calls} AS c
             WHERE c.id = t.llm_cost_tracker_call_id AND t.id IN (#{list})
          SQL
        end

        def behavior_for(entry)
          entry[:behavior] || LlmCostTracker.configuration.budgets.exceeded_behavior
        end

        def on_exceeded_for(entry)
          entry[:on_exceeded] || LlmCostTracker.configuration.budgets.on_exceeded
        end

        def warn_slow_read(key, window, seconds)
          return if seconds < SLOW_READ_SECONDS

          @slow_keys ||= Set.new
          return unless @slow_keys.add?(key)

          reason = if WINDOW_STARTS.key?(window)
                     "A tag with few distinct values covers most of the ledger, so its budget check cannot use " \
                       "an index effectively. Budget high-cardinality tags such as a tenant or user id."
                   else
                     "A #{window} limit sums every call the value has recorded, so it suits short-lived values " \
                       "such as a run."
                   end
          Logging.warn(
            "config.budgets.per_tag[#{key.inspect}] #{window} read took #{(seconds * 1000).round} ms. #{reason}"
          )
        end

        def warn_missing_columns
          return if @missing_columns_warned

          @missing_columns_warned = true
          Logging.warn(
            "config.budgets.per_tag is set but llm_cost_tracker_call_tags is missing " \
            "#{COST_COLUMN} / #{TIME_COLUMN}; per-tag budgets are not enforced. Run the " \
            "upgrade_per_tag_budgets generator and migrate, or clear config.budgets.per_tag."
          )
        end
      end
    end
  end
end
