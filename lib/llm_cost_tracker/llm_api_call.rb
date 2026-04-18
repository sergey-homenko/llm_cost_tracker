# frozen_string_literal: true

require "active_record"

require_relative "tag_accessors"
require_relative "tag_query"
require_relative "tags_column"

module LlmCostTracker
  class LlmApiCall < ActiveRecord::Base
    extend TagsColumn
    include TagAccessors

    self.table_name = "llm_api_calls"

    # Scopes for querying
    scope :by_provider, ->(provider) { where(provider: provider) }
    scope :by_model,    ->(model)    { where(model: model) }
    scope :by_user,    ->(user_id) { by_tag("user_id", user_id) }
    scope :by_feature, ->(feature) { by_tag("feature", feature) }
    scope :with_cost, -> { where.not(total_cost: nil) }
    scope :without_cost, -> { where(total_cost: nil) }
    scope :unknown_pricing, -> { without_cost }
    scope :with_latency, -> { latency_column? ? where.not(latency_ms: nil) : none }

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

    # Aggregations
    def self.total_cost
      sum(:total_cost).to_f
    end

    def self.total_tokens
      sum(:total_tokens).to_i
    end

    def self.cost_by_model
      group(:model).sum(:total_cost)
    end

    def self.cost_by_provider
      group(:provider).sum(:total_cost)
    end

    def self.average_latency_ms
      return nil unless latency_column?

      average(:latency_ms)&.to_f
    end

    def self.latency_by_model
      return {} unless latency_column?

      group(:model).average(:latency_ms).transform_values(&:to_f)
    end

    def self.latency_by_provider
      return {} unless latency_column?

      group(:provider).average(:latency_ms).transform_values(&:to_f)
    end

    def self.daily_costs(days: 30)
      where(tracked_at: days.days.ago..)
        .group("DATE(tracked_at)")
        .sum(:total_cost)
        .transform_keys(&:to_s)
    end
  end
end
