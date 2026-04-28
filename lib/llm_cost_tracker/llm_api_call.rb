# frozen_string_literal: true

require "active_record"

require_relative "llm_api_call_metrics"
require_relative "period_grouping"
require_relative "tag_accessors"
require_relative "tag_query"
require_relative "tags_column"

module LlmCostTracker
  class LlmApiCall < ActiveRecord::Base
    extend PeriodGrouping
    extend TagsColumn
    extend LlmApiCallMetrics
    include TagAccessors

    self.table_name = "llm_api_calls"

    scope :with_cost, -> { where.not(total_cost: nil) }
    scope :without_cost, -> { where(total_cost: nil) }
    scope :unknown_pricing, -> { without_cost }
    scope :with_latency, -> { latency_column? ? where.not(latency_ms: nil) : none }
    scope :streaming,     -> { stream_column? ? where(stream: true) : none }
    scope :non_streaming, -> { stream_column? ? where(stream: [false, nil]) : all }
    scope :by_usage_source, ->(source) { usage_source_column? ? where(usage_source: source.to_s) : none }
    scope :with_provider_response_id, lambda {
      provider_response_id_column? ? where.not(provider_response_id: [nil, ""]) : none
    }
    scope :missing_provider_response_id, lambda {
      provider_response_id_column? ? where(provider_response_id: [nil, ""]) : none
    }
    scope :streaming_missing_usage, lambda {
      return none unless stream_column? && usage_source_column?

      where(stream: true).where(usage_source: ["unknown", nil])
    }

    scope :with_json_tags, lambda {
      if tags_json_column?
        where.not(tags: {})
      else
        where.not(tags: [nil, "", "{}"])
      end
    }

    scope :today,       -> { where(tracked_at: Time.now.utc.beginning_of_day..) }
    scope :this_week,   -> { where(tracked_at: Time.now.utc.beginning_of_week..) }
    scope :this_month,  -> { where(tracked_at: Time.now.utc.beginning_of_month..) }
    scope :between,     ->(from, to) { where(tracked_at: from..to) }

    def self.by_tag(key, value)
      by_tags(key => value)
    end

    def self.by_tags(tags)
      TagQuery.apply(self, tags)
    end
  end
end
