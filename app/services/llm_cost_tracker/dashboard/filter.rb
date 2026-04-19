# frozen_string_literal: true

require "date"

module LlmCostTracker
  module Dashboard
    # Parses dashboard params into an ActiveRecord relation.
    #
    # Invalid dates are ignored, pagination is handled elsewhere, and invalid
    # tag keys raise InvalidFilterError so controllers can fail closed with HTTP 400.
    class Filter
      class << self
        def call(scope: LlmCostTracker::LlmApiCall.all, params: {})
          new(scope: scope, params: params).relation
        end
      end

      def initialize(scope:, params:)
        @scope = scope
        @params = normalize_params(params)
      end

      def relation
        filtered_scope = scope
        filtered_scope = apply_date_filters(filtered_scope)
        filtered_scope = apply_exact_filter(filtered_scope, :provider)
        filtered_scope = apply_exact_filter(filtered_scope, :model)
        apply_tag_filters(filtered_scope)
      end

      private

      attr_reader :scope, :params

      def normalize_params(params)
        return {} if params.nil?
        return params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
        return params.to_h if params.respond_to?(:to_h)

        {}
      end

      def apply_date_filters(relation)
        from = parse_date(:from)&.beginning_of_day
        to = parse_date(:to)&.end_of_day

        relation = relation.where(tracked_at: from..) if from
        relation = relation.where(tracked_at: ..to) if to
        relation
      end

      def apply_exact_filter(relation, key)
        value = string_param(key)
        return relation if value.nil?

        relation.where(key => value)
      end

      def apply_tag_filters(relation)
        tags = tag_params
        return relation if tags.empty?

        relation.by_tags(tags)
      end

      def tag_params
        tags = hash_param(:tag)
        tag_key = string_param(:tag_key)
        tag_value = string_param(:tag_value)
        tags = tags.merge(tag_key => tag_value) if tag_key && tag_value

        tags.each_with_object({}) do |(key, value), normalized|
          value = normalized_string(value)
          next if value.nil?

          normalized[LlmCostTracker::TagKey.validate!(key, error_class: LlmCostTracker::InvalidFilterError)] = value
        end
      end

      def hash_param(key)
        raw = params[key] || params[key.to_s]
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw = raw.to_h if raw.respond_to?(:to_h)
        raw.is_a?(Hash) ? raw : {}
      end

      def parse_date(key)
        value = string_param(key)
        return nil if value.nil?

        Date.iso8601(value)
      rescue ArgumentError
        nil
      end

      def string_param(key)
        normalized_string(params[key] || params[key.to_s])
      end

      def normalized_string(value)
        return nil if value.nil?

        value = value.to_s.strip
        value.empty? ? nil : value
      end
    end
  end
end
