# frozen_string_literal: true

require "llm_cost_tracker/pricing"
require "llm_cost_tracker/ledger/schema/adapter"

module LlmCostTracker
  module Dashboard
    class DataQuality
      class << self
        def call(scope: LlmCostTracker::Ledger::Call.all)
          scope.unscope(:order).select(aggregate_selects(scope)).take
        end

        def unknown_pricing_by_model(scope)
          scope.unknown_pricing
               .group(:model)
               .order(Arel.sql("COUNT(*) DESC"))
               .select("model, COUNT(*) AS calls")
               .limit(10)
        end

        def usage_rows(stats)
          billable_tokens = stats.billable_tokens.to_f

          rows = Pricing::COMPONENTS.map do |component|
            token_key = component.token_key
            cost_key = component.cost_key
            token_value = stats[token_key].to_i
            share_percent = if billable_tokens.positive?
                              (token_value.to_f / billable_tokens) * 100.0
                            else
                              0.0
                            end

            {
              price_key: component.price_key,
              token_key: token_key,
              cost_key: cost_key,
              token_value: token_value,
              cost_value: stats[cost_key],
              share_percent: share_percent,
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

        def aggregate_selects(scope)
          selects = [
            "COUNT(*) AS total_calls",
            "#{conditional_count_sql('total_cost IS NULL')} AS unknown_pricing_count",
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
          Pricing::COMPONENTS.map(&:token_key) + [:hidden_output_tokens] + Pricing::COMPONENTS.map(&:cost_key)
        end

        def billable_tokens_select(scope)
          Pricing::COMPONENTS
            .map { |component| column_sum(scope, component.token_key) }
            .join(" + ")
        end

        def hidden_output_share_select(scope)
          hidden_output = column_sum(scope, :hidden_output_tokens)
          output = column_sum(scope, :output_tokens)

          "CASE WHEN #{output} > 0 THEN #{hidden_output} * 100.0 / #{output} ELSE 0 END"
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
