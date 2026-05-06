# frozen_string_literal: true

require "llm_cost_tracker/billing/components"
require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Dashboard
    class DataQuality
      UnknownPricingRow = ::Data.define(:model, :calls, :share_percent)
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
          charge_table = LlmCostTracker::ServiceCharge.quoted_table_name
          relation = LlmCostTracker::ServiceCharge
                     .joins(:call)
                     .merge(scope.unscope(:select, :order))

          relation
            .group("#{call_table}.provider", "#{charge_table}.component", "#{charge_table}.cost_status")
            .order(Arel.sql("COALESCE(SUM(#{charge_table}.cost), 0) DESC"), Arel.sql("COUNT(*) DESC"))
            .select(
              "#{call_table}.provider AS provider",
              "#{charge_table}.component AS component",
              "#{charge_table}.cost_status AS cost_status",
              "COUNT(*) AS charges_count",
              "COALESCE(SUM(#{charge_table}.quantity), 0) AS quantity",
              "COALESCE(SUM(#{charge_table}.cost), 0) AS total_cost"
            )
            .limit(10)
        end

        def usage_rows(stats)
          billable_tokens = stats.billable_tokens.to_f

          rows = Billing::Components::TOKEN_PRICED.map do |component|
            token_key = component.token_key
            cost_key = component.cost_key
            token_value = stats[token_key].to_i

            {
              price_key: component.key,
              token_key: token_key,
              cost_key: cost_key,
              token_value: token_value,
              cost_value: stats[cost_key],
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
          Billing::Components::TOKEN_PRICED.map(&:token_key) + [:hidden_output_tokens] +
            Billing::Components::TOKEN_PRICED.map(&:cost_key)
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
          table = scope.klass.quoted_table_name
          connection = scope.connection
          column = "#{table}.#{connection.quote_column_name('tags')}"

          if Ledger::Schema::Adapter.postgresql?(connection)
            "COALESCE(SUM(CASE WHEN #{column} <> '{}'::jsonb THEN 1 ELSE 0 END), 0)"
          else
            "COALESCE(SUM(CASE WHEN JSON_LENGTH(#{column}) > 0 THEN 1 ELSE 0 END), 0)"
          end
        end
      end
    end
  end
end
