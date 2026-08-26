# frozen_string_literal: true

require_relative "../ledger/schema/adapter"
require_relative "../ledger/tags/encoding"

module LlmCostTracker
  module Budget
    module PerTag
      COST_COLUMN = "total_cost"
      TIME_COLUMN = "tracked_at"
      WINDOW_STARTS = { daily: :beginning_of_day, weekly: :beginning_of_week, monthly: :beginning_of_month }.freeze
      SLOW_READ_SECONDS = 0.1
      DEFAULT_BACKFILL_BATCH = 5_000

      Rule = Data.define(:key, :value, :windows, :behavior, :on_exceeded)

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
          active? && configured.each_value.any? { |entry| behavior_for(entry) == :block_requests }
        end

        def rules_for(tags, blocking_only: false)
          return [] unless active?

          normalized = (tags || {}).to_h.transform_keys(&:to_s)
          configured.filter_map do |key, entry|
            raw = normalized[key]
            next if raw.nil?
            next if blocking_only && behavior_for(entry) != :block_requests

            Rule.new(
              key: key,
              value: Ledger::Tags::Encoding.encode(raw),
              windows: entry[:windows],
              behavior: behavior_for(entry),
              on_exceeded: on_exceeded_for(entry)
            )
          end
        end

        def spend(key, value, window, time:)
          start = time.to_time.utc.public_send(WINDOW_STARTS.fetch(window))
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          total = LlmCostTracker::CallTag
                  .where(key: key, value: value, TIME_COLUMN => start..time)
                  .sum(COST_COLUMN).to_d
          warn_slow_read(key, window, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
          total
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
          (LlmCostTracker::CallTag.column_names & [COST_COLUMN, TIME_COLUMN]).size == 2
        end

        private

        def copy_next_batch(batch_size)
          ids = LlmCostTracker::CallTag.where(TIME_COLUMN => nil).limit(batch_size).pluck(:id)
          return 0 if ids.empty?

          LlmCostTracker::CallTag.connection.update(copy_sql(ids))
        end

        def copy_sql(ids)
          tags = LlmCostTracker::CallTag.quoted_table_name
          calls = LlmCostTracker::Call.quoted_table_name
          list = ids.join(",")
          return <<~SQL.squish unless Ledger::Schema::Adapter.postgresql?(LlmCostTracker::CallTag.connection)
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

          Logging.warn(
            "config.budgets.per_tag[#{key.inspect}] #{window} read took #{(seconds * 1000).round} ms. " \
            "A tag with few distinct values covers most of the ledger, so its budget check cannot use " \
            "an index effectively. Budget high-cardinality tags such as a tenant or user id."
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
