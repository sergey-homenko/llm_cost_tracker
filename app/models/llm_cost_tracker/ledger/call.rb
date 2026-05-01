# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ledger
    class Call < ActiveRecord::Base
      extend Period::Grouping
      extend Ledger::CallMetrics
      include Ledger::Tags::Accessors

      self.table_name = "llm_api_calls"

      scope :with_cost, -> { where.not(total_cost: nil) }
      scope :without_cost, -> { where(total_cost: nil) }
      scope :unknown_pricing, -> { without_cost }
      scope :with_latency, -> { where.not(latency_ms: nil) }
      scope :streaming,     -> { where(stream: true) }
      scope :non_streaming, -> { where(stream: [false, nil]) }
      scope :by_usage_source, ->(source) { where(usage_source: source.to_s) }
      scope :with_provider_response_id, -> { where.not(provider_response_id: [nil, ""]) }
      scope :missing_provider_response_id, -> { where(provider_response_id: [nil, ""]) }
      scope :streaming_missing_usage, lambda {
        where(stream: true).where(usage_source: ["unknown", nil])
      }

      scope :with_json_tags, lambda {
        where.not(tags: {})
      }

      scope :today,       -> { where(tracked_at: Time.now.utc.beginning_of_day..) }
      scope :this_week,   -> { where(tracked_at: Time.now.utc.beginning_of_week..) }
      scope :this_month,  -> { where(tracked_at: Time.now.utc.beginning_of_month..) }
      scope :between,     ->(from, to) { where(tracked_at: from..to) }

      def self.by_tag(key, value)
        by_tags(key => value)
      end

      def self.by_tags(tags)
        Ledger::Tags::Query.apply(tags)
      end
    end
  end
end
