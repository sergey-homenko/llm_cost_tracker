# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class LlmApiCall < ActiveRecord::Base
    self.table_name = "llm_api_calls"

    # Scopes for querying
    scope :by_provider, ->(provider) { where(provider: provider) }
    scope :by_model,    ->(model)    { where(model: model) }
    scope :by_tag, lambda { |key, value|
      where("tags LIKE ?", "%\"#{key}\":\"#{value}\"%")
    }

    scope :today,       -> { where(tracked_at: Time.now.utc.beginning_of_day..) }
    scope :this_week,   -> { where(tracked_at: Time.now.utc.beginning_of_week..) }
    scope :this_month,  -> { where(tracked_at: Time.now.utc.beginning_of_month..) }
    scope :between,     ->(from, to) { where(tracked_at: from..to) }

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

    def self.daily_costs(days: 30)
      where(tracked_at: days.days.ago..)
        .group("DATE(tracked_at)")
        .sum(:total_cost)
    end

    def parsed_tags
      JSON.parse(tags || "{}")
    rescue JSON::ParserError
      {}
    end

    def feature
      parsed_tags["feature"]
    end

    def user_id
      parsed_tags["user_id"]
    end
  end
end
