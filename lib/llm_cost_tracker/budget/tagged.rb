# frozen_string_literal: true

require_relative "per_tag"
require_relative "../tags/context"

module LlmCostTracker
  module Budget
    module Tagged
      class << self
        def enforce!(tags, estimate, time:, blocking_only:)
          PerTag.rules_for(tags || Tags::Context.tags, blocking_only: blocking_only).each do |rule|
            rule.windows.each_key do |window|
              limit = rule.limit(window)
              total = PerTag.spend(rule.key, rule.value, window, time: time) + limit.charge(estimate)
              limit.block!(total) if limit.over?(total)
            end
          end
        end

        def post_spend_errors(events, behavior_override)
          window_buckets(scored_rules(events, behavior_override)).flat_map do |(key, window, bucket), recorded_by_rule|
            upto = recorded_by_rule.values.flatten.map(&:tracked_at).max unless Ingestion.async?
            totals = PerTag.spend_by_value(key, recorded_by_rule.keys.map(&:value), window, bucket, upto)
            recorded_by_rule.filter_map do |rule, recorded|
              total, total_through_batch = totals.fetch(rule.value, [0, 0])
              bucket_error(rule.limit(window), recorded, total, total_through_batch, behavior_override)
            end
          end
        end

        def notify_repriced(changes, time:)
          PerTag.rules_for_events(changes).each do |rule, repriced|
            rule.windows.except(:calls).each_key do |window|
              limit = rule.limit(window)
              amount = limit.amount_in_window(repriced, time)
              total = PerTag.spend(rule.key, rule.value, window, time: time) if rule.on_exceeded && amount.positive?
              next unless total && limit.over?(total)

              limit.handle_exceeded(total: total, previous_total: total - amount, behavior_override: :notify)
            end
          end
        end

        private

        def scored_rules(events, behavior_override)
          by_rule = PerTag.rules_for_events(events)
          behavior_override == :notify ? by_rule.reject { |rule, _| rule.on_exceeded.nil? } : by_rule
        end

        def bucket_error(limit, recorded, total, total_through_batch, behavior_override)
          return unless limit.over?(total)

          reference = limit.over?(total_through_batch) ? total_through_batch : total
          limit.handle_exceeded(total: total,
                                previous_total: reference - recorded.sum { |event| limit.charge(event.total_cost) },
                                last_event: recorded.last,
                                behavior_override: behavior_override)
        end

        def window_buckets(by_rule)
          by_rule.each_with_object({}) do |(rule, events), grouped|
            rule.windows.each_key do |window|
              limit = rule.limit(window)
              events.select { |event| limit.counts?(event) }
                    .group_by { |event| PerTag.window_start(window, event.tracked_at) }
                    .each { |bucket, bucket_events| (grouped[[rule.key, window, bucket]] ||= {})[rule] = bucket_events }
            end
          end
        end
      end
    end
  end
end
