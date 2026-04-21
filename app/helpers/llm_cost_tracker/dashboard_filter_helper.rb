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
      tag_params = normalized_query_tags(params[:tag])
      return [] unless tag_params.is_a?(Hash)

      tag_params.filter_map do |key, value|
        next if key.blank? || value.blank?

        {
          label: "Tag",
          value: "#{key}=#{value}",
          path: dashboard_filter_path(current_query(tag: tag_params.except(key.to_s).presence, page: nil))
        }
      end
    end

    def dashboard_date_range_label(from, to)
      from_label = short_date_label(from) || "Any time"
      to_label = short_date_label(to) || "Now"
      "#{from_label} - #{to_label}"
    end

    private

    def short_date_label(value)
      return nil if value.blank?

      Date.iso8601(value.to_s).strftime("%b %-d, %Y")
    rescue ArgumentError
      value.to_s
    end
  end
end
