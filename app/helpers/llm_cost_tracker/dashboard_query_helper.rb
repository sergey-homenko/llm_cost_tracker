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
      tags = LlmCostTracker::ParameterHash.to_hash(query[:tag]).transform_keys(&:to_s).transform_values(&:to_s)
      query[:tag] = tags.merge(key.to_s => value.to_s)
      query
    end

    private

    def clean_dashboard_query(value)
      if value.is_a?(Hash) || value.try(:to_unsafe_h).is_a?(Hash)
        return LlmCostTracker::ParameterHash.to_hash(value).each_with_object({}) do |(key, nested), cleaned|
          nested = clean_dashboard_query(nested)
          next if nested.nil? || nested == {} || nested == []

          cleaned[key] = nested
        end
      end

      return value.filter_map { |item| clean_dashboard_query(item) }.presence if value.is_a?(Array)
      return value.strip.presence if value.is_a?(String)

      value
    end
  end
end
