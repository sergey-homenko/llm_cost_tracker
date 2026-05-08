# frozen_string_literal: true

require "llm_cost_tracker/billing/components"
require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Dashboard
    class DataQuality
      UnknownPricingRow = ::Data.define(:model, :calls, :share_percent)
      StreamingHealthRow = ::Data.define(:provider, :streams, :with_usage, :unknown, :unknown_share)
      Summary = ::Data.define(:total, :unknown_pricing_count, :untagged_calls_count, :missing_latency_count,
                              :streaming_count, :streaming_missing_usage, :missing_provider_response_id_count,
                              :calls_with_pricing, :tagged_calls, :calls_with_latency, :streams_with_usage,
                              :calls_with_provider_response_id, :unknown_pricing_share, :untagged_share,
                              :missing_latency_share, :streaming_share, :streaming_missing_usage_share,
                              :cost_coverage, :tag_coverage, :latency_coverage, :stream_coverage,
                              :provider_response_id_coverage)

      class << self
        def call(scope: LlmCostTracker::Call.all)
          scope.unscope(:order).select(aggregate_selects(scope)).take
        end

        def summary(stats)
          total = stats.total_calls.to_i
          unknown_pricing_count = stats.unknown_pricing_count.to_i
          untagged_calls_count = stats.untagged_calls_count.to_i
          missing_latency_count = stats.missing_latency_count.to_i
          streaming_count = stats.streaming_count.to_i
          streaming_missing_usage = stats.streaming_missing_usage_count.to_i
          missing_provider_response_id_count = stats.missing_provider_response_id_count.to_i
          calls_with_pricing = total - unknown_pricing_count
          tagged_calls = total - untagged_calls_count
          calls_with_latency = total - missing_latency_count
          streams_with_usage = streaming_count - streaming_missing_usage
          calls_with_provider_response_id = total - missing_provider_response_id_count

          Summary.new(
            total, unknown_pricing_count, untagged_calls_count, missing_latency_count, streaming_count,
            streaming_missing_usage, missing_provider_response_id_count, calls_with_pricing, tagged_calls,
            calls_with_latency, streams_with_usage, calls_with_provider_response_id,
            percentage(unknown_pricing_count, total), percentage(untagged_calls_count, total),
            percentage(missing_latency_count, total), percentage(streaming_count, total),
            percentage(streaming_missing_usage, streaming_count), percentage(calls_with_pricing, total),
            percentage(tagged_calls, total), percentage(calls_with_latency, total),
            percentage(streams_with_usage, streaming_count), percentage(calls_with_provider_response_id, total)
          )
        end

        def unknown_pricing_by_model(scope, total_calls:)
          scope.unknown_pricing
               .group(:model)
               .order(Arel.sql("COUNT(*) DESC"))
               .select("model, COUNT(*) AS calls")
               .limit(10)
               .map do |row|
                 calls = row.calls.to_i
                 UnknownPricingRow.new(model: row.model, calls: calls, share_percent: percentage(calls, total_calls))
               end
        end

        def service_charge_rows(scope)
          call_table = LlmCostTracker::Call.quoted_table_name
          line_item_table = LlmCostTracker::CallLineItem.quoted_table_name
          relation = LlmCostTracker::CallLineItem
                     .where.not(unit: "token")
                     .joins(:call)
                     .merge(scope.unscope(:select, :order))

          relation
            .group("#{call_table}.provider", "#{line_item_table}.kind", "#{line_item_table}.cost_status")
            .order(Arel.sql("COALESCE(SUM(#{line_item_table}.cost), 0) DESC"), Arel.sql("COUNT(*) DESC"))
            .select(
              "#{call_table}.provider AS provider",
              "#{line_item_table}.kind AS component",
              "#{line_item_table}.cost_status AS cost_status",
              "COUNT(*) AS charges_count",
              "COALESCE(SUM(#{line_item_table}.quantity), 0) AS quantity",
              "COALESCE(SUM(#{line_item_table}.cost), 0) AS total_cost"
            )
            .limit(10)
        end

        def usage_rows(stats, component_costs: {})
          billable_tokens = stats.billable_tokens.to_f

          rows = Billing::Components::TOKEN_PRICED.map do |component|
            token_value = stats[component.token_key].to_i

            {
              price_key: component.key,
              token_key: component.token_key,
              cost_key: component.cost_key,
              token_value: token_value,
              cost_value: component_costs[component.key],
              share_percent: percentage(token_value, billable_tokens),
              share_basis: nil
            }
          end

          rows + [
            {
              price_key: nil,
              token_key: :hidden_output_tokens,
              cost_key: nil,
              token_value: stats.hidden_output_tokens.to_i,
              cost_value: nil,
              share_percent: stats.hidden_output_share.to_f,
              share_basis: :output
            }
          ]
        end

        def component_costs(scope)
          line_item_table = LlmCostTracker::CallLineItem.quoted_table_name
          rows = LlmCostTracker::CallLineItem
                 .where(unit: "token")
                 .joins(:call)
                 .merge(scope.unscope(:select, :order, :group))
                 .group("#{line_item_table}.kind", "#{line_item_table}.direction",
                        "#{line_item_table}.cache_state")
                 .pluck(Arel.sql("#{line_item_table}.kind"),
                        Arel.sql("#{line_item_table}.direction"),
                        Arel.sql("#{line_item_table}.cache_state"),
                        Arel.sql("COALESCE(SUM(#{line_item_table}.cost), 0)"))
          index_costs_by_component(rows)
        end

        def streaming_health_rows(scope, total_streaming:)
          return [] unless total_streaming.positive?

          unknown_predicate = "usage_source = 'unknown' OR usage_source IS NULL"
          rows = scope.unscope(:select, :order, :group)
                      .where(stream: true)
                      .group(:provider)
                      .order(Arel.sql("COUNT(*) DESC"), :provider)
                      .pluck(
                        :provider,
                        Arel.sql("COUNT(*)"),
                        Arel.sql("SUM(CASE WHEN #{unknown_predicate} THEN 1 ELSE 0 END)")
                      )

          rows.map do |provider, streams, unknown|
            streams_count = streams.to_i
            unknown_count = unknown.to_i
            StreamingHealthRow.new(
              provider: provider,
              streams: streams_count,
              with_usage: streams_count - unknown_count,
              unknown: unknown_count,
              unknown_share: percentage(unknown_count, streams_count)
            )
          end
        end

        def hidden_output_summary(stats)
          output_tokens = stats.output_tokens.to_i
          return unless output_tokens.positive?

          {
            hidden_output_tokens: stats.hidden_output_tokens.to_i,
            output_tokens: output_tokens,
            share_percent: stats.hidden_output_share.to_f
          }
        end

        private

        def index_costs_by_component(rows)
          rows.each_with_object({}) do |(kind, direction, cache_state, cost), accumulator|
            component = Billing::Components::TOKEN_PRICED.find do |item|
              item.kind.to_s == kind.to_s &&
                item.direction.to_s == direction.to_s &&
                item.cache_state.to_s == cache_state.to_s
            end
            accumulator[component.key] = cost if component
          end
        end

        def percentage(numerator, denominator)
          return 0.0 unless denominator.positive?

          (numerator.to_f / denominator) * 100.0
        end

        def aggregate_selects(scope)
          selects = [
            "COUNT(*) AS total_calls",
            "#{conditional_count_sql(unknown_pricing_predicate(scope))} AS unknown_pricing_count",
            "#{tagged_calls_sql(scope)} AS tagged_calls_count",
            "COUNT(*) - #{tagged_calls_sql(scope)} AS untagged_calls_count",
            "#{conditional_count_sql('latency_ms IS NULL')} AS missing_latency_count",
            "#{conditional_count_sql('stream')} AS streaming_count",
            "#{streaming_missing_usage_select} AS streaming_missing_usage_count",
            "#{provider_response_id_select} AS missing_provider_response_id_count"
          ]

          usage_sum_columns.each do |column|
            selects << "#{column_sum(scope, column)} AS #{column}"
          end

          selects << "#{billable_tokens_select(scope)} AS billable_tokens"
          selects << "#{hidden_output_share_select(scope)} AS hidden_output_share"

          selects.join(", ")
        end

        def usage_sum_columns
          Billing::Components::TOKEN_PRICED.map(&:token_key) + [:hidden_output_tokens]
        end

        def billable_tokens_select(scope)
          Billing::Components::TOKEN_PRICED
            .map { |component| column_sum(scope, component.token_key) }
            .join(" + ")
        end

        def hidden_output_share_select(scope)
          hidden_output = column_sum(scope, :hidden_output_tokens)
          output = column_sum(scope, :output_tokens)

          "CASE WHEN #{output} > 0 THEN #{hidden_output} * 100.0 / #{output} ELSE 0 END"
        end

        def unknown_pricing_predicate(scope)
          values = [
            LlmCostTracker::Billing::CostStatus::UNKNOWN,
            LlmCostTracker::Billing::CostStatus::PARTIAL
          ].map { |value| scope.connection.quote(value) }

          "total_cost IS NULL OR cost_status IN (#{values.join(', ')})"
        end

        def column_sum(scope, column)
          "COALESCE(SUM(#{scope.connection.quote_column_name(column)}), 0)"
        end

        def conditional_count_sql(predicate)
          "COALESCE(SUM(CASE WHEN #{predicate} THEN 1 ELSE 0 END), 0)"
        end

        def streaming_missing_usage_select
          predicate = "stream AND (usage_source = 'unknown' OR usage_source IS NULL)"
          conditional_count_sql(predicate)
        end

        def provider_response_id_select
          predicate = "provider_response_id IS NULL OR provider_response_id = ''"
          conditional_count_sql(predicate)
        end

        def tagged_calls_sql(scope)
          calls_table = scope.klass.quoted_table_name
          tags_table = LlmCostTracker::CallTag.quoted_table_name

          "COALESCE(SUM(CASE WHEN EXISTS (SELECT 1 FROM #{tags_table} " \
            "WHERE #{tags_table}.llm_cost_tracker_call_id = #{calls_table}.id) THEN 1 ELSE 0 END), 0)"
        end
      end
    end
  end
end
