# frozen_string_literal: true

require "date"

module LlmCostTracker
  module Dashboard
    class Filter
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all, params: {})
          new(scope: scope, params: params).relation
        end
      end

      def initialize(scope:, params:)
        @scope = scope
        @params = LlmCostTracker::ParameterHash.with_indifferent_access(params)
      end

      def relation
        filtered_scope = scope
        filtered_scope = apply_date_filters(filtered_scope)
        filtered_scope = apply_exact_filter(filtered_scope, :provider)
        filtered_scope = apply_exact_filter(filtered_scope, :model)
        filtered_scope = apply_stream_filter(filtered_scope)
        filtered_scope = apply_usage_source_filter(filtered_scope)
        apply_tag_filters(filtered_scope)
      end

      private

      attr_reader :scope, :params

      def apply_date_filters(relation)
        from_date = parse_date(:from)
        to_date = parse_date(:to)
        Dashboard::DateRange.validate!(from: from_date, to: to_date)

        from = from_date&.beginning_of_day
        to = to_date&.end_of_day
        relation = relation.where(tracked_at: from..) if from
        relation = relation.where(tracked_at: ..to) if to
        relation
      end

      def apply_exact_filter(relation, key)
        value = normalized_string(params[key])
        return relation if value.nil?

        relation.where(key => value)
      end

      def apply_tag_filters(relation)
        tags = tag_params
        return relation if tags.empty?

        relation.by_tags(tags)
      end

      def apply_stream_filter(relation)
        value = normalized_string(params[:stream])
        return relation if value.nil?
        return relation unless relation.klass.stream_column?

        case value.downcase
        when "yes", "true", "1" then relation.where(stream: true)
        when "no", "false", "0" then relation.where(stream: [false, nil])
        else relation
        end
      end

      def apply_usage_source_filter(relation)
        value = normalized_string(params[:usage_source])
        return relation if value.nil?
        return relation unless relation.klass.usage_source_column?

        relation.where(usage_source: value)
      end

      def tag_params
        tags = hash_param(:tag)

        tags.each_with_object({}) do |(key, value), normalized|
          value = normalized_string(value)
          next if value.nil?

          normalized[LlmCostTracker::TagKey.validate!(key, error_class: LlmCostTracker::InvalidFilterError)] = value
        end
      end

      def hash_param(key)
        LlmCostTracker::ParameterHash.to_hash(params[key])
      end

      def parse_date(key)
        Dashboard::DateRange.parse(params, key)
      end

      def normalized_string(value)
        return nil if value.nil?

        value = value.to_s.strip
        value.empty? ? nil : value
      end
    end
  end
end
