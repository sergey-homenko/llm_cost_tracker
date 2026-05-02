# frozen_string_literal: true

module LlmCostTracker
  module DashboardFilterHelper
    FILTER_PARAM_KEYS = %i[from to provider model stream usage_source tag sort page per].freeze

    STREAM_FILTER_OPTIONS = [
      ["Streaming only", "yes"],
      ["Non-streaming only", "no"]
    ].freeze

    def any_filter_applied?
      FILTER_PARAM_KEYS.any? { |key| params[key].present? }
    end

    def active_tag_filters
      tag_params = LlmCostTracker::Dashboard::Params.to_hash(params[:tag]).transform_keys(&:to_s).transform_values(&:to_s)

      tag_params.filter_map do |key, value|
        next if key.blank? || value.blank?

        {
          label: "Tag",
          value: "#{key}=#{value}",
          path: dashboard_filter_path(current_query(tag: tag_params.except(key.to_s).presence, page: nil))
        }
      end
    end
  end
end
