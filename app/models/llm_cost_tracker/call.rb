# frozen_string_literal: true

require "securerandom"

module LlmCostTracker
  class Call < ActiveRecord::Base
    before_validation :assign_event_id

    scope :with_cost, -> { where.not(total_cost: nil) }
    scope :without_cost, -> { where(total_cost: nil) }
    scope :unknown_pricing,
          lambda {
            where(Charges::CostStatus.unknown_pricing_sql)
          }
    scope :with_latency, -> { where.not(latency_ms: nil) }
    scope :streaming,     -> { where(stream: true) }
    scope :non_streaming, -> { where(stream: [false, nil]) }
    scope :by_usage_source, ->(source) { where(usage_source: source.to_s) }
    scope :with_provider_response_id, -> { where.not(provider_response_id: [nil, ""]) }
    scope :missing_provider_response_id, -> { where(provider_response_id: [nil, ""]) }
    scope :streaming_missing_usage,
          lambda {
            where(stream: true).where(usage_source: [Usage::Source::UNKNOWN, nil])
          }

    has_many :line_items,
             class_name: "LlmCostTracker::CallLineItem",
             foreign_key: :llm_cost_tracker_call_id,
             inverse_of: :call,
             dependent: :delete_all

    has_many :tag_records,
             class_name: "LlmCostTracker::CallTag",
             foreign_key: :llm_cost_tracker_call_id,
             inverse_of: :call,
             dependent: :delete_all

    scope :today,       -> { where(tracked_at: Time.now.utc.beginning_of_day..) }
    scope :this_week,   -> { where(tracked_at: Time.now.utc.beginning_of_week..) }
    scope :this_month,  -> { where(tracked_at: Time.now.utc.beginning_of_month..) }
    scope :between,     ->(from, to) { where(tracked_at: from..to) }

    class << self
      def already_recorded?(provider:, provider_response_id:)
        return false if provider_response_id.to_s.empty?

        where(provider: provider, provider_response_id: provider_response_id).exists?
      end

      def by_tag(key, value) = by_tags(key => value)

      def by_tags(tags) = Ledger::Tags::Query.apply(tags)

      def total_cost = sum(:total_cost).to_f

      def total_tokens = sum(:total_tokens).to_i

      def cost_by_model(limit: nil) = cost_by_column(:model, limit: limit)

      def cost_by_provider(limit: nil) = cost_by_column(:provider, limit: limit)

      def group_by_tag(key)
        Ledger::Tags::Breakdown.join_relation(self, key).group(Ledger::Tags::Breakdown.value_arel)
      end

      def cost_by_tag(key, limit: nil)
        cost = qualified_total_cost
        label = Ledger::Tags::Breakdown.label_sql(connection)
        raw_value = Ledger::Tags::Breakdown.raw_value_sql(connection)
        relation = Ledger::Tags::Breakdown.join_relation(self, key)
                                          .select("#{label} AS name", "COALESCE(SUM(#{cost}), 0) AS total_cost")
                                          .group(Arel.sql(label))
                                          .order(
                                            Arel.sql("COALESCE(SUM(#{cost}), 0) DESC"),
                                            Arel.sql("MAX(CASE WHEN #{raw_value} IS NULL THEN 1 ELSE 0 END) ASC"),
                                            Arel.sql("#{label} DESC")
                                          )
        relation = relation.limit(limit) if limit
        relation
      end

      def average_latency_ms = average(:latency_ms)&.to_f

      def latency_by_model = group(:model).average(:latency_ms).transform_values(&:to_f)

      def latency_by_provider = group(:provider).average(:latency_ms).transform_values(&:to_f)

      def group_by_period(period, column: :tracked_at)
        group(Arel.sql(period_group_expression(period, column: column)))
      end

      def daily_costs(days: 30)
        where(tracked_at: days.days.ago..)
          .group_by_period(:day)
          .sum(:total_cost)
      end

      def qualified_total_cost
        "#{quoted_table_name}.#{connection.quote_column_name(:total_cost)}"
      end

      private

      def cost_by_column(column, limit:)
        relation = select(arel_table[column].as("name"), "COALESCE(SUM(total_cost), 0) AS total_cost")
                   .group(column)
                   .order(Arel.sql("COALESCE(SUM(total_cost), 0) DESC"))
        relation = relation.limit(limit) if limit
        relation
      end

      def period_group_expression(period, column:)
        Ledger::Schema::Adapter.period_bucket_sql(connection, period, period_column_expression(column))
      end

      def period_column_expression(column)
        column = column.to_s
        return "#{quoted_table_name}.#{connection.quote_column_name(column)}" if column_names.include?(column)

        raise ArgumentError, "invalid period column: #{column.inspect}"
      end
    end

    def tag_pairs
      tag_records.to_h do |record|
        [record.key, record.value]
      end
    end

    private

    def assign_event_id
      self.event_id ||= SecureRandom.uuid
    end
  end
end
