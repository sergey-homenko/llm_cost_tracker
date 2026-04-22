# frozen_string_literal: true

module LlmCostTracker
  module DashboardQueryHelper
    def dashboard_filter_path(query)
      cleaned = clean_dashboard_query(query)
      return request.path if cleaned.blank?

      "#{request.path}?#{cleaned.to_query}"
    end

    def calls_query_for_tag(key:, value:)
      query = current_query(page: nil, per: nil, format: nil)
      tags = normalized_query_tags(query[:tag])
      query[:tag] = tags.merge(key.to_s => value.to_s)
      query
    end

    private

    def normalized_query_tags(tags)
      LlmCostTracker::ParameterHash.to_hash(tags).transform_keys(&:to_s).transform_values(&:to_s)
    end

    def clean_dashboard_query(value)
      if LlmCostTracker::ParameterHash.hash_like?(value)
        return clean_dashboard_hash(LlmCostTracker::ParameterHash.to_hash(value))
      end

      return clean_dashboard_array(value) if value.is_a?(Array)
      return clean_dashboard_string(value) if value.is_a?(String)

      value
    end

    def clean_dashboard_hash(hash)
      hash.each_with_object({}) do |(key, nested), cleaned|
        nested = clean_dashboard_query(nested)
        next if nested.nil? || nested == {} || nested == []

        cleaned[key] = nested
      end
    end

    def clean_dashboard_array(array)
      array.filter_map { |item| clean_dashboard_query(item) }.presence
    end

    def clean_dashboard_string(string)
      stripped = string.strip
      stripped.empty? ? nil : stripped
    end
  end
end
