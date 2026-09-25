# frozen_string_literal: true

require "date"

module LlmCostTracker
  module Dashboard
    class Filter
      MAX_TAG_FILTERS = 10
      MATCH_NOTHING = Arel.sql("1 = 0")
      STREAM_FILTER_OPTIONS = [
        ["Streaming only", "yes"],
        ["Non-streaming only", "no"]
      ].freeze

      class << self
        def call(scope: LlmCostTracker::Call.all, params: {}, tags: {})
          new(scope: scope, params: params, tags: tags).relation
        end
      end

      def initialize(scope:, params:, tags: {})
        @scope = scope
        @params = LlmCostTracker::Dashboard::Params.to_hash(params).symbolize_keys
        @extra_tags = tags
      end

      def relation
        filtered_scope = scope
        filtered_scope = apply_date_filters(filtered_scope)
        filtered_scope = apply_exact_filter(filtered_scope, :provider)
        filtered_scope = apply_exact_filter(filtered_scope, :model)
        filtered_scope = apply_stream_filter(filtered_scope)
        filtered_scope = apply_exact_filter(filtered_scope, :usage_source)
        apply_tag_filters(filtered_scope)
      end

      private

      attr_reader :scope, :params, :extra_tags

      def apply_date_filters(relation)
        from_date = Dashboard::DateRange.parse(params, :from)
        to_date = Dashboard::DateRange.parse(params, :to)
        Dashboard::DateRange.validate!(from: from_date, to: to_date)

        default_range = Dashboard::DateRange.call(params: params)
        from_date ||= default_range.from
        to_date ||= default_range.to

        relation
          .where(tracked_at: from_date.beginning_of_day..)
          .where(tracked_at: ..to_date.end_of_day)
      end

      def apply_exact_filter(relation, key)
        value = normalized_string(params[key], key)
        return relation if value.nil?

        matchable?([value]) ? relation.where(key => value) : relation.where(MATCH_NOTHING)
      end

      def apply_tag_filters(relation)
        tags = tag_params.merge(extra_tags)
        return relation if tags.empty?
        if tags.size > MAX_TAG_FILTERS
          raise LlmCostTracker::InvalidFilterError,
                "at most #{MAX_TAG_FILTERS} tag filters are allowed, got #{tags.size}"
        end

        matchable?(tags.values) ? relation.by_tags(tags) : relation.where(MATCH_NOTHING)
      end

      def apply_stream_filter(relation)
        value = normalized_string(params[:stream], :stream)
        return relation if value.nil?

        case value.downcase
        when "yes", "true", "1" then relation.where(stream: true)
        when "no", "false", "0" then relation.where(stream: [false, nil])
        else relation
        end
      end

      def tag_params
        tags = LlmCostTracker::Dashboard::Params.to_hash(params[:tag])

        tags.each_with_object({}) do |(key, value), normalized|
          value = normalized_string(value, "tag filter value")
          next if value.nil?

          normalized[LlmCostTracker::Tags::Key.validate!(key, error_class: LlmCostTracker::InvalidFilterError)] = value
        end
      end

      def matchable?(values)
        values.none? { |value| value.include?("\0") } ||
          !LlmCostTracker::Ledger::Schema::Adapter.postgresql?(scope.connection)
      end

      def normalized_string(value, name)
        LlmCostTracker::Dashboard::Params.scalar(value, name).strip.presence
      end
    end
  end
end
