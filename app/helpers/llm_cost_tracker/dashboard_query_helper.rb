# frozen_string_literal: true

module LlmCostTracker
  module DashboardQueryHelper
    EMPTY_QUERY_VALUES = [nil, {}, []].freeze

    def current_query(overrides = {})
      request.query_parameters.symbolize_keys.slice(*Dashboard::Params::QUERY_KEYS).merge(overrides)
    end

    def calls_query_for_model(provider:, model:)
      current_query(provider: provider, model: model, page: nil, per: nil, format: nil)
    end

    def calls_query_for_tag(key:, value:)
      query = current_query(page: nil, per: nil, format: nil)
      tags = Dashboard::Params.tag_query(query[:tag])
      query[:tag] = tags.merge(key.to_s => value.to_s)
      query
    end

    def tag_drilldown_allowed?(key)
      tags = Dashboard::Params.tag_query(current_query[:tag])
      tags.except(key.to_s).size < Dashboard::Filter::MAX_TAG_FILTERS
    end

    def dashboard_filter_path(query)
      cleaned = clean_dashboard_query(query)
      return request.path if cleaned.blank?

      "#{request.path}?#{cleaned.to_query}"
    end

    def hidden_query_fields(query, prefix: nil)
      safe_join(query.flat_map do |key, value|
        name = prefix ? "#{prefix}[#{key}]" : key.to_s
        case value
        when Hash then hidden_query_fields(value, prefix: name)
        when Array then value.map { |item| hidden_field_tag("#{name}[]", item, id: nil) }
        else hidden_field_tag(name, value, id: nil)
        end
      end)
    end

    private

    def clean_dashboard_query(value)
      case value
      when Array then value.filter_map { |item| clean_dashboard_query(item) }.presence
      when String then value.strip.presence
      else query_hash?(value) ? clean_query_hash(value) : value
      end
    end

    def clean_query_hash(hash)
      Dashboard::Params.to_hash(hash).each_with_object({}) do |(key, value), cleaned|
        value = clean_dashboard_query(value)
        cleaned[key] = value unless EMPTY_QUERY_VALUES.include?(value)
      end
    end

    def query_hash?(value)
      value.is_a?(Hash) || value.try(:to_unsafe_h).is_a?(Hash)
    end
  end
end
