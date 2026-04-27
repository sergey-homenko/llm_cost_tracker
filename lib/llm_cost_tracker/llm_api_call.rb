# frozen_string_literal: true

require "active_record"

require_relative "period_grouping"
require_relative "tag_accessors"
require_relative "tag_key"
require_relative "tag_query"
require_relative "tags_column"

module LlmCostTracker
  class LlmApiCall < ActiveRecord::Base
    extend PeriodGrouping
    extend TagsColumn
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

    def self.group_by_tag(key)
      group(Arel.sql(tag_value_expression(key)))
    end

    def self.cost_by_tag(key)
      costs = group_by_tag(key).sum(:total_cost).each_with_object(Hash.new(0.0)) do |(tag_value, cost), grouped|
        grouped[tag_value_label(tag_value)] += cost.to_f
      end
      costs.sort_by { |_label, cost| -cost }.to_h
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

    def self.tag_value_label(value)
      value.nil? || value == "" ? "(untagged)" : value.to_s
    end

    def self.tag_value_expression(key, table_name: quoted_table_name)
      key = validated_tag_key(key)
      column = "#{table_name}.#{connection.quote_column_name('tags')}"

      case connection.adapter_name
      when /postgres/i
        json_column = tags_jsonb_column? ? column : "(#{column})::jsonb"
        "#{json_column}->>#{connection.quote(key)}"
      when /mysql/i
        "JSON_UNQUOTE(JSON_EXTRACT(#{column}, #{connection.quote(json_path(key))}))"
      else
        "json_extract(#{column}, #{connection.quote(json_path(key))})"
      end
    end

    def self.validated_tag_key(key)
      TagKey.validate!(key)
    end
    private_class_method :validated_tag_key

    def self.json_path(key)
      "$.\"#{key}\""
    end
    private_class_method :json_path
  end
end
