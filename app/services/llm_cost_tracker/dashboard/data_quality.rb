# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module DataQuality
      UnknownPricingRow = ::Data.define(:provider, :model, :calls, :share_percent)
      QuarantinedInbox = ::Data.define(:count, :total_cost)
      UnseenBudgetTags = ::Data.define(:keys)
      StreamingHealthRow = ::Data.define(:provider, :streams, :with_usage, :unknown, :unknown_share)

      class << self
        def call(scope: LlmCostTracker::Call.all)
          StatsQuery.call(scope)
        end

        def summary(stats)
          Summary.from_stats(stats)
        end

        def unknown_usage_sql(connection)
          "usage_source = #{connection.quote(LlmCostTracker::Usage::Source::UNKNOWN)} OR usage_source IS NULL"
        end

        def quarantined_inbox
          return nil unless Ingestion.async? && Ingestion::InboxEntry.table_exists?

          row = Ingestion::InboxEntry
                .quarantined
                .select("COUNT(*) AS quarantined_count, COALESCE(SUM(total_cost), 0) AS quarantined_cost")
                .take
          QuarantinedInbox.new(count: row.quarantined_count.to_i, total_cost: row.quarantined_cost.to_d)
        end

        def unseen_budget_tags
          budgeted = Budget::PerTag.configured
          return nil if budgeted.empty? || !Budget::PerTag.columns? || !LlmCostTracker::CallTag.exists?

          unseen = budgeted.keys.reject { |key| LlmCostTracker::CallTag.where(key: key).where.not(value: "").exists? }
          UnseenBudgetTags.new(keys: unseen) unless unseen.empty?
        end

        def unknown_pricing_by_model(scope, total_calls:)
          scope.unknown_pricing
               .group(:provider, :model)
               .order(Arel.sql("COUNT(*) DESC"))
               .select("provider, model, COUNT(*) AS calls")
               .limit(10)
               .map do |row|
                 calls = row.calls.to_i
                 UnknownPricingRow.new(provider: row.provider,
                                       model: row.model,
                                       calls: calls,
                                       share_percent: Percent.of(calls, total_calls))
               end
        end

        def service_charge_rows(scope)
          call_table = LlmCostTracker::Call.quoted_table_name
          item_table = LlmCostTracker::CallLineItem.quoted_table_name

          LlmCostTracker::CallLineItem
            .where.not(unit: "token")
            .joins(:call)
            .merge(scope.unscope(:select, :order))
            .group("#{call_table}.provider", "#{item_table}.kind", "#{item_table}.cost_status")
            .order(Arel.sql("COALESCE(SUM(#{item_table}.cost), 0) DESC"), Arel.sql("COUNT(*) DESC"))
            .select(
              "#{call_table}.provider AS provider",
              "#{item_table}.kind AS component",
              "#{item_table}.cost_status AS cost_status",
              "COUNT(*) AS charges_count",
              "COALESCE(SUM(#{item_table}.quantity), 0) AS quantity",
              "COALESCE(SUM(#{item_table}.cost), 0) AS total_cost"
            )
            .limit(10)
        end

        def component_costs(scope)
          item_table = LlmCostTracker::CallLineItem.quoted_table_name
          dimensions = %w[kind direction cache_state].map { |column| "#{item_table}.#{column}" }
          rows = LlmCostTracker::CallLineItem
                 .where(unit: "token")
                 .joins(:call)
                 .merge(scope.unscope(:select, :order, :group))
                 .group(*dimensions)
                 .pluck(*dimensions.map { |column| Arel.sql(column) }, Arel.sql("COALESCE(SUM(#{item_table}.cost), 0)"))
          Usage::Catalog.costs_by_component(rows)
        end

        def usage_rows(stats, component_costs: {})
          billable_tokens = stats.billable_tokens.to_f
          rows = Usage::Catalog.token_priced.map do |component|
            token_value = stats[component.token_key].to_i
            {
              token_key: component.token_key,
              cost_key: component.cost_key,
              token_value: token_value,
              cost_value: component_costs[component.key],
              share_percent: Percent.of(token_value, billable_tokens),
              share_basis: nil
            }
          end
          rows << hidden_output_usage_row(stats)
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

        def streaming_health_rows(scope, total_streaming:)
          return [] unless total_streaming.positive?

          unknown_count = Arel.sql("SUM(CASE WHEN #{unknown_usage_sql(scope.lease_connection)} THEN 1 ELSE 0 END)")
          scope.unscope(:select, :order, :group)
               .where(stream: true)
               .group(:provider)
               .order(Arel.sql("COUNT(*) DESC"), :provider)
               .pluck(:provider, Arel.sql("COUNT(*)"), unknown_count)
               .map { |provider, streams, unknown| streaming_health_row(provider, streams.to_i, unknown.to_i) }
        end

        private

        def hidden_output_usage_row(stats)
          {
            token_key: :hidden_output_tokens,
            cost_key: nil,
            token_value: stats.hidden_output_tokens.to_i,
            cost_value: nil,
            share_percent: stats.hidden_output_share.to_f,
            share_basis: :output
          }
        end

        def streaming_health_row(provider, streams, unknown)
          StreamingHealthRow.new(
            provider: provider,
            streams: streams,
            with_usage: streams - unknown,
            unknown: unknown,
            unknown_share: Percent.of(unknown, streams)
          )
        end
      end
    end
  end
end
